// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Therminos — on-chain thermometer for asset price and volatility. Tracks heat bands (cold/mild/warm/hot/critical)
 * from price snapshots and rolling volatility. Suited for risk dashboards and circuit-breaker triggers.
 * Calibration thresholds and updater roles set at deploy; no external oracle dependency in core logic.
 */

contract Therminos {

    uint256 private _reentrancyFlag;

    event HeatLevelChanged(
        bytes32 indexed symbolHash,
        uint8 previousBand,
        uint8 newBand,
        uint256 priceE8,
        uint256 volatilityE8,
        uint256 atBlock
    );
    event BandCrossed(
        bytes32 indexed symbolHash,
        uint8 fromBand,
        uint8 toBand,
        uint256 atBlock
    );
    event VolatilitySpike(
        bytes32 indexed symbolHash,
        uint256 volatilityE8,
        uint256 thresholdE8,
        uint256 atBlock
    );
    event PriceReported(
        bytes32 indexed symbolHash,
        uint256 priceE8,
        address indexed reporter,
        uint256 atBlock
    );
    event ThermometerRegistered(bytes32 indexed symbolHash, uint256 windowBlocks, uint256 atBlock);
    event ThermometerRemoved(bytes32 indexed symbolHash, uint256 atBlock);
    event ThresholdsUpdated(
        uint256 coldBps,
        uint256 mildBps,
        uint256 warmBps,
        uint256 hotBps,
        uint256 atBlock
    );
    event UpdaterSet(address indexed previous, address indexed current, uint256 atBlock);
    event GuardianSet(address indexed previous, address indexed current, uint256 atBlock);
    event PlatformPauseToggled(bool paused, uint256 atBlock);
    event TreasurySweep(address indexed to, uint256 amountWei, uint256 atBlock);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SnapshotAppended(bytes32 indexed symbolHash, uint256 priceE8, uint256 atBlock);
    event CooldownConfigured(bytes32 indexed symbolHash, uint256 cooldownBlocks, uint256 atBlock);
    event BatchPricesReported(bytes32[] symbolHashes, uint256[] pricesE8, address indexed reporter, uint256 atBlock);
    event EmergencyHalt(bytes32 indexed symbolHash, uint256 atBlock);
    event EmergencyLift(bytes32 indexed symbolHash, uint256 atBlock);
    event MaxHistoryLengthUpdated(uint256 previous, uint256 current, uint256 atBlock);
    event FeeWeiUpdated(uint256 previous, uint256 current, uint256 atBlock);

    error THRM_NotOwner();
    error THRM_NotUpdater();
    error THRM_NotGuardian();
    error THRM_ZeroAddress();
    error THRM_ZeroPrice();
    error THRM_ZeroAmount();
    error THRM_PlatformPaused();
    error THRM_SymbolNotFound();
    error THRM_SymbolAlreadyRegistered();
    error THRM_MaxThermometersReached();
    error THRM_InvalidBand();
    error THRM_InvalidThresholdOrder();
    error THRM_TransferFailed();
    error THRM_ReentrantCall();
    error THRM_ArrayLengthMismatch();
    error THRM_BatchTooLarge();
    error THRM_HistoryFull();
    error THRM_WindowTooShort();
    error THRM_WindowTooLong();
    error THRM_CooldownActive();
    error THRM_SymbolHalted();
    error THRM_InsufficientPayment();
    error THRM_InvalidIndex();
    error THRM_NoThermometers();
    error THRM_SameValue();
    error THRM_InvalidFeeWei();

    uint256 public constant THRM_BPS_BASE = 10000;
    uint256 public constant THRM_BAND_COLD = 0;
    uint256 public constant THRM_BAND_MILD = 1;
    uint256 public constant THRM_BAND_WARM = 2;
    uint256 public constant THRM_BAND_HOT = 3;
    uint256 public constant THRM_BAND_CRITICAL = 4;
    uint256 public constant THRM_MAX_THERMOMETERS = 96;
    uint256 public constant THRM_MIN_WINDOW_BLOCKS = 12;
    uint256 public constant THRM_MAX_WINDOW_BLOCKS = 40320;
    uint256 public constant THRM_MAX_HISTORY_LEN = 720;
    uint256 public constant THRM_MAX_BATCH_REPORT = 32;
    uint256 public constant THRM_DOMAIN_SALT = 0x5F2b8E1c4A7d0D3f6B9a2C5e8F1b4D7c0A3e6;
    bytes32 public constant THRM_GENESIS_DOMAIN = keccak256("Therminos.Heat.v2");

    address public owner;
    address public immutable treasury;
    address public guardian;
    address public updater;
    uint256 public immutable deployBlock;
    bytes32 public immutable genesisHash;

    uint256 public thermometerCount;
    uint256 public reportFeeWei;
    uint256 public maxHistoryLength;
    bool public platformPaused;

    uint256 public coldBps;
    uint256 public mildBps;
    uint256 public warmBps;
    uint256 public hotBps;

    struct PricePoint {
        uint256 priceE8;
        uint256 blockNumber;
    }

    struct ThermoSlot {
        bytes32 symbolHash;
        uint256 windowBlocks;
        uint256 cooldownBlocks;
        uint256 lastReportBlock;
        uint256[] priceHistoryE8;
        uint256[] blockHistory;
        uint8 currentBand;
        uint256 currentVolatilityE8;
        uint256 currentPriceE8;
        bool halted;
        uint256 registeredAtBlock;
    }

    mapping(bytes32 => ThermoSlot) public thermometers;
    mapping(bytes32 => uint256) public symbolToIndex;
    bytes32[] public registeredSymbols;
    mapping(bytes32 => uint256[]) private _bandHistoryBlocks;
    mapping(bytes32 => uint8[]) private _bandHistoryValues;
    uint256 public globalReportSequence;

    modifier onlyOwner() {
        if (msg.sender != owner) revert THRM_NotOwner();
        _;
    }

    modifier onlyUpdater() {
        if (msg.sender != updater && msg.sender != owner) revert THRM_NotUpdater();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian && msg.sender != owner) revert THRM_NotGuardian();
        _;
    }

    modifier whenNotPaused() {
        if (platformPaused) revert THRM_PlatformPaused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyFlag != 0) revert THRM_ReentrantCall();
        _reentrancyFlag = 1;
        _;
        _reentrancyFlag = 0;
    }

    constructor() {
        owner = msg.sender;
        treasury = address(0xd4F8b2E6a0C5e9D1f7A3c8B6E4d2F0a9C1e5D7);
        guardian = address(0x7E1a9C4d2F6b0A8e3D5c1B9f7E2a4D0c6F8b3);
        updater = address(0x2A6c0E4f8B1d3D9a7C5e2F0b6A4c8E1d3F7a9);
        deployBlock = block.number;
        genesisHash = keccak256(abi.encodePacked("Therminos", block.chainid, block.prevrandao, THRM_DOMAIN_SALT));
        coldBps = 500;
        mildBps = 1500;
        warmBps = 3500;
        hotBps = 7000;
        maxHistoryLength = 168;
        reportFeeWei = 0;
    }

    function setThresholds(
        uint256 _coldBps,
        uint256 _mildBps,
        uint256 _warmBps,
        uint256 _hotBps
    ) external onlyOwner {
        if (_coldBps >= _mildBps || _mildBps >= _warmBps || _warmBps >= _hotBps || _hotBps > THRM_BPS_BASE) revert THRM_InvalidThresholdOrder();
        coldBps = _coldBps;
        mildBps = _mildBps;
        warmBps = _warmBps;
        hotBps = _hotBps;
        emit ThresholdsUpdated(_coldBps, _mildBps, _warmBps, _hotBps, block.number);
    }

    function setUpdater(address newUpdater) external onlyOwner {
        if (newUpdater == address(0)) revert THRM_ZeroAddress();
        address prev = updater;
        updater = newUpdater;
        emit UpdaterSet(prev, newUpdater, block.number);
    }

    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert THRM_ZeroAddress();
        address prev = guardian;
        guardian = newGuardian;
        emit GuardianSet(prev, newGuardian, block.number);
    }

    function setPlatformPaused(bool paused) external onlyGuardian {
        platformPaused = paused;
        emit PlatformPauseToggled(paused, block.number);
    }

    function setReportFeeWei(uint256 feeWei) external onlyOwner {
        if (feeWei > 1e15) revert THRM_InvalidFeeWei();
        uint256 prev = reportFeeWei;
        reportFeeWei = feeWei;
        emit FeeWeiUpdated(prev, feeWei, block.number);
    }

    function setMaxHistoryLength(uint256 len) external onlyOwner {
        if (len > THRM_MAX_HISTORY_LEN) len = THRM_MAX_HISTORY_LEN;
        uint256 prev = maxHistoryLength;
        maxHistoryLength = len;
        emit MaxHistoryLengthUpdated(prev, len, block.number);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert THRM_ZeroAddress();
        address prev = owner;
        owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }

    function registerThermometer(bytes32 symbolHash, uint256 windowBlocks) external onlyOwner whenNotPaused {
        if (thermometers[symbolHash].registeredAtBlock != 0) revert THRM_SymbolAlreadyRegistered();
        if (thermometerCount >= THRM_MAX_THERMOMETERS) revert THRM_MaxThermometersReached();
        if (windowBlocks < THRM_MIN_WINDOW_BLOCKS) revert THRM_WindowTooShort();
        if (windowBlocks > THRM_MAX_WINDOW_BLOCKS) revert THRM_WindowTooLong();

        thermometers[symbolHash] = ThermoSlot({
            symbolHash: symbolHash,
            windowBlocks: windowBlocks,
            cooldownBlocks: 0,
            lastReportBlock: 0,
            priceHistoryE8: new uint256[](0),
            blockHistory: new uint256[](0),
            currentBand: 0,
            currentVolatilityE8: 0,
            currentPriceE8: 0,
            halted: false,
            registeredAtBlock: block.number
        });
        thermometerCount++;
        registeredSymbols.push(symbolHash);
        symbolToIndex[symbolHash] = registeredSymbols.length;
        emit ThermometerRegistered(symbolHash, windowBlocks, block.number);
    }

    function removeThermometer(bytes32 symbolHash) external onlyOwner {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        delete thermometers[symbolHash];
        thermometerCount--;
        emit ThermometerRemoved(symbolHash, block.number);
    }

    function setCooldown(bytes32 symbolHash, uint256 cooldownBlocks) external onlyOwner {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        thermometers[symbolHash].cooldownBlocks = cooldownBlocks;
        emit CooldownConfigured(symbolHash, cooldownBlocks, block.number);
    }

    function emergencyHalt(bytes32 symbolHash) external onlyGuardian {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        thermometers[symbolHash].halted = true;
        emit EmergencyHalt(symbolHash, block.number);
    }

    function emergencyLift(bytes32 symbolHash) external onlyGuardian {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        thermometers[symbolHash].halted = false;
        emit EmergencyLift(symbolHash, block.number);
    }

    function _computeVolatilityE8(ThermoSlot storage slot) internal view returns (uint256 volE8) {
        uint256[] storage prices = slot.priceHistoryE8;
        uint256[] storage blocks = slot.blockHistory;
        uint256 w = slot.windowBlocks;
        if (prices.length < 2) return 0;
        uint256 n = prices.length;
        uint256 sum;
        uint256 count;
        for (uint256 i = n - 1; i > 0; ) {
            if (blocks[n - 1] - blocks[i - 1] > w) break;
            uint256 pCur = prices[i];
            uint256 pPrev = prices[i - 1];
            if (pPrev == 0) {
                unchecked { --i; }
                continue;
            }
            uint256 changeBps = (pCur > pPrev)
                ? ((pCur - pPrev) * THRM_BPS_BASE) / pPrev
                : ((pPrev - pCur) * THRM_BPS_BASE) / pPrev;
            sum += changeBps;
            count++;
            unchecked { --i; }
        }
        if (count == 0) return 0;
        return (sum * 1e8) / (count * THRM_BPS_BASE);
    }

    function _bandFromVolatilityBps(uint256 volatilityBps) internal view returns (uint8) {
        if (volatilityBps <= coldBps) return uint8(THRM_BAND_COLD);
        if (volatilityBps <= mildBps) return uint8(THRM_BAND_MILD);
        if (volatilityBps <= warmBps) return uint8(THRM_BAND_WARM);
        if (volatilityBps <= hotBps) return uint8(THRM_BAND_HOT);
        return uint8(THRM_BAND_CRITICAL);
    }

    function reportPrice(bytes32 symbolHash, uint256 priceE8) external payable onlyUpdater whenNotPaused nonReentrant {
        if (msg.value < reportFeeWei) revert THRM_InsufficientPayment();
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        if (thermometers[symbolHash].halted) revert THRM_SymbolHalted();
        if (priceE8 == 0) revert THRM_ZeroPrice();

        ThermoSlot storage slot = thermometers[symbolHash];
        if (slot.cooldownBlocks > 0 && block.number < slot.lastReportBlock + slot.cooldownBlocks) revert THRM_CooldownActive();

        uint256[] storage prices = slot.priceHistoryE8;
        uint256[] storage blocks = slot.blockHistory;
        if (prices.length >= maxHistoryLength) revert THRM_HistoryFull();

        uint8 prevBand = slot.currentBand;
        slot.currentPriceE8 = priceE8;
        slot.lastReportBlock = block.number;
        prices.push(priceE8);
        blocks.push(block.number);

        slot.currentVolatilityE8 = _computeVolatilityE8(slot);
        uint256 volBps = (slot.currentVolatilityE8 * THRM_BPS_BASE) / 1e8;
        uint8 newBand = _bandFromVolatilityBps(volBps);
        slot.currentBand = newBand;

        _bandHistoryBlocks[symbolHash].push(block.number);
        _bandHistoryValues[symbolHash].push(newBand);

        globalReportSequence++;

        emit PriceReported(symbolHash, priceE8, msg.sender, block.number);
        emit SnapshotAppended(symbolHash, priceE8, block.number);
        emit HeatLevelChanged(symbolHash, prevBand, newBand, priceE8, slot.currentVolatilityE8, block.number);
        if (prevBand != newBand) emit BandCrossed(symbolHash, prevBand, newBand, block.number);
        if (newBand >= THRM_BAND_HOT) emit VolatilitySpike(symbolHash, slot.currentVolatilityE8, hotBps * 1e8 / THRM_BPS_BASE, block.number);

        if (reportFeeWei > 0 && address(this).balance >= reportFeeWei) {
            (bool ok,) = treasury.call{value: reportFeeWei}("");
            if (!ok) revert THRM_TransferFailed();
            emit TreasurySweep(treasury, reportFeeWei, block.number);
        }
    }

    function batchReportPrices(
        bytes32[] calldata symbolHashes,
        uint256[] calldata pricesE8
    ) external payable onlyUpdater whenNotPaused nonReentrant {
        uint256 n = symbolHashes.length;
        if (n != pricesE8.length) revert THRM_ArrayLengthMismatch();
        if (n == 0 || n > THRM_MAX_BATCH_REPORT) revert THRM_BatchTooLarge();
        if (msg.value < reportFeeWei * n) revert THRM_InsufficientPayment();

        for (uint256 i; i < n; ) {
            bytes32 sh = symbolHashes[i];
            uint256 pe = pricesE8[i];
            if (thermometers[sh].registeredAtBlock != 0 && !thermometers[sh].halted && pe != 0) {
                ThermoSlot storage slot = thermometers[sh];
                if (slot.cooldownBlocks == 0 || block.number >= slot.lastReportBlock + slot.cooldownBlocks) {
                    if (slot.priceHistoryE8.length < maxHistoryLength) {
                        uint8 prevBand = slot.currentBand;
                        slot.currentPriceE8 = pe;
                        slot.lastReportBlock = block.number;
                        slot.priceHistoryE8.push(pe);
                        slot.blockHistory.push(block.number);
                        slot.currentVolatilityE8 = _computeVolatilityE8(slot);
                        uint256 volBps = (slot.currentVolatilityE8 * THRM_BPS_BASE) / 1e8;
                        uint8 newBand = _bandFromVolatilityBps(volBps);
                        slot.currentBand = newBand;
                        _bandHistoryBlocks[sh].push(block.number);
                        _bandHistoryValues[sh].push(newBand);
                        emit PriceReported(sh, pe, msg.sender, block.number);
                        emit HeatLevelChanged(sh, prevBand, newBand, pe, slot.currentVolatilityE8, block.number);
                        if (prevBand != newBand) emit BandCrossed(sh, prevBand, newBand, block.number);
                    }
                }
            }
            unchecked { ++i; }
        }
        globalReportSequence++;
        emit BatchPricesReported(symbolHashes, pricesE8, msg.sender, block.number);

        uint256 totalFee = reportFeeWei * n;
        if (totalFee > 0 && address(this).balance >= totalFee) {
            (bool ok,) = treasury.call{value: totalFee}("");
            if (!ok) revert THRM_TransferFailed();
            emit TreasurySweep(treasury, totalFee, block.number);
        }
    }

    function sweepTreasury(uint256 amountWei) external onlyOwner nonReentrant {
        if (amountWei == 0) revert THRM_ZeroAmount();
        uint256 bal = address(this).balance;
        if (amountWei > bal) amountWei = bal;
        (bool ok,) = treasury.call{value: amountWei}("");
        if (!ok) revert THRM_TransferFailed();
        emit TreasurySweep(treasury, amountWei, block.number);
    }

    function getThermometer(bytes32 symbolHash) external view returns (
        uint256 windowBlocks,
        uint256 cooldownBlocks,
        uint256 lastReportBlock,
        uint8 currentBand,
        uint256 currentVolatilityE8,
        uint256 currentPriceE8,
        bool halted,
        uint256 registeredAtBlock,
        uint256 historyLength
    ) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        return (
            s.windowBlocks,
            s.cooldownBlocks,
            s.lastReportBlock,
            s.currentBand,
            s.currentVolatilityE8,
            s.currentPriceE8,
            s.halted,
            s.registeredAtBlock,
            s.priceHistoryE8.length
        );
    }

    function getPriceHistory(bytes32 symbolHash, uint256 offset, uint256 limit) external view returns (
        uint256[] memory pricesE8,
        uint256[] memory blocks
    ) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256 len = s.priceHistoryE8.length;
        if (offset >= len) return (new uint256[](0), new uint256[](0));
        if (limit == 0 || offset + limit > len) limit = len - offset;
        pricesE8 = new uint256[](limit);
        blocks = new uint256[](limit);
        for (uint256 i; i < limit; ) {
            pricesE8[i] = s.priceHistoryE8[offset + i];
            blocks[i] = s.blockHistory[offset + i];
            unchecked { ++i; }
        }
    }

    function getBandHistory(bytes32 symbolHash, uint256 offset, uint256 limit) external view returns (
        uint8[] memory bands,
        uint256[] memory blocks
    ) {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256[] storage blks = _bandHistoryBlocks[symbolHash];
        uint8[] storage bnds = _bandHistoryValues[symbolHash];
        uint256 len = blks.length;
        if (offset >= len) return (new uint8[](0), new uint256[](0));
        if (limit == 0 || offset + limit > len) limit = len - offset;
        bands = new uint8[](limit);
        blocks = new uint256[](limit);
        for (uint256 i; i < limit; ) {
            bands[i] = bnds[offset + i];
            blocks[i] = blks[offset + i];
            unchecked { ++i; }
        }
    }

    function getRegisteredSymbols() external view returns (bytes32[] memory) {
        return registeredSymbols;
    }

    function getHeatSummary() external view returns (
        bytes32[] memory symbolHashes,
        uint8[] memory bands,
        uint256[] memory volatilitiesE8,
        uint256[] memory pricesE8
    ) {
        uint256 n = registeredSymbols.length;
        if (n == 0) revert THRM_NoThermometers();
        symbolHashes = new bytes32[](n);
        bands = new uint8[](n);
        volatilitiesE8 = new uint256[](n);
        pricesE8 = new uint256[](n);
        for (uint256 i; i < n; ) {
            bytes32 sh = registeredSymbols[i];
            ThermoSlot storage s = thermometers[sh];
            symbolHashes[i] = sh;
            bands[i] = s.currentBand;
            volatilitiesE8[i] = s.currentVolatilityE8;
            pricesE8[i] = s.currentPriceE8;
            unchecked { ++i; }
        }
    }

    function getVolatilityE8(bytes32 symbolHash) external view returns (uint256) {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        return thermometers[symbolHash].currentVolatilityE8;
    }

    function getCurrentBand(bytes32 symbolHash) external view returns (uint8) {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        return thermometers[symbolHash].currentBand;
    }

    function getCurrentPriceE8(bytes32 symbolHash) external view returns (uint256) {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        return thermometers[symbolHash].currentPriceE8;
    }

    function isHalted(bytes32 symbolHash) external view returns (bool) {
        return thermometers[symbolHash].halted;
    }

    function getThresholds() external view returns (uint256 _coldBps, uint256 _mildBps, uint256 _warmBps, uint256 _hotBps) {
        return (coldBps, mildBps, warmBps, hotBps);
    }

    function computeBandForVolatilityBps(uint256 volatilityBps) external view returns (uint8) {
        return _bandFromVolatilityBps(volatilityBps);
    }

    function getGenesisHash() external view returns (bytes32) {
        return genesisHash;
    }

    function getDeployBlock() external view returns (uint256) {
        return deployBlock;
    }

    receive() external payable {}

    function _trimHistoryIfNeeded(bytes32 symbolHash) internal {
        ThermoSlot storage s = thermometers[symbolHash];
        uint256 len = s.priceHistoryE8.length;
        if (len <= maxHistoryLength) return;
        uint256 remove = len - maxHistoryLength;
        for (uint256 i; i < remove; ) {
            for (uint256 j; j < len - 1; ) {
                s.priceHistoryE8[j] = s.priceHistoryE8[j + 1];
                s.blockHistory[j] = s.blockHistory[j + 1];
                unchecked { ++j; }
            }
            s.priceHistoryE8.pop();
            s.blockHistory.pop();
            len = s.priceHistoryE8.length;
            unchecked { ++i; }
        }
    }

    function trimHistory(bytes32 symbolHash) external onlyOwner {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        _trimHistoryIfNeeded(symbolHash);
    }

    function getLatestPricePoint(bytes32 symbolHash) external view returns (uint256 priceE8, uint256 blockNum) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256 len = s.priceHistoryE8.length;
        if (len == 0) return (0, 0);
        return (s.priceHistoryE8[len - 1], s.blockHistory[len - 1]);
    }

    function getPriceAtBlock(bytes32 symbolHash, uint256 blockNum) external view returns (uint256 priceE8, bool found) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256[] storage blocks = s.blockHistory;
        uint256[] storage prices = s.priceHistoryE8;
        for (uint256 i = blocks.length; i > 0; ) {
            unchecked { --i; }
            if (blocks[i] <= blockNum) {
                return (prices[i], true);
            }
        }
        return (0, false);
    }

    function countThermometersInBand(uint8 band) external view returns (uint256) {
        if (band > THRM_BAND_CRITICAL) revert THRM_InvalidBand();
        uint256 count;
        for (uint256 i; i < registeredSymbols.length; ) {
            if (thermometers[registeredSymbols[i]].currentBand == band) count++;
            unchecked { ++i; }
        }
        return count;
    }

    function getSymbolHashesInBand(uint8 band) external view returns (bytes32[] memory) {
        if (band > THRM_BAND_CRITICAL) revert THRM_InvalidBand();
        uint256 n = registeredSymbols.length;
        uint256 count;
        for (uint256 i; i < n; ) {
            if (thermometers[registeredSymbols[i]].currentBand == band) count++;
            unchecked { ++i; }
        }
        bytes32[] memory out = new bytes32[](count);
        count = 0;
        for (uint256 i; i < n; ) {
            if (thermometers[registeredSymbols[i]].currentBand == band) {
                out[count] = registeredSymbols[i];
                count++;
            }
            unchecked { ++i; }
        }
        return out;
    }

    function getVolatilityBps(bytes32 symbolHash) external view returns (uint256) {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        return (thermometers[symbolHash].currentVolatilityE8 * THRM_BPS_BASE) / 1e8;
    }

    function getNextReportBlock(bytes32 symbolHash) external view returns (uint256) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        if (s.cooldownBlocks == 0) return block.number;
        uint256 next = s.lastReportBlock + s.cooldownBlocks;
        if (block.number >= next) return block.number;
        return next;
    }

    function canReport(bytes32 symbolHash) external view returns (bool) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0 || s.halted) return false;
        if (s.cooldownBlocks == 0) return true;
        return block.number >= s.lastReportBlock + s.cooldownBlocks;
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getGlobalReportSequence() external view returns (uint256) {
        return globalReportSequence;
    }

    function bandLabel(uint8 band) external pure returns (string memory) {
        if (band == THRM_BAND_COLD) return "cold";
        if (band == THRM_BAND_MILD) return "mild";
        if (band == THRM_BAND_WARM) return "warm";
        if (band == THRM_BAND_HOT) return "hot";
        if (band == THRM_BAND_CRITICAL) return "critical";
        return "unknown";
    }

    function estimateVolatilityE8(bytes32 symbolHash) external view returns (uint256) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        return _computeVolatilityE8(s);
    }

    function getSlotByIndex(uint256 index) external view returns (
        bytes32 symbolHash,
        uint8 currentBand,
        uint256 currentPriceE8,
        uint256 currentVolatilityE8,
        bool halted
    ) {
        if (index >= registeredSymbols.length) revert THRM_InvalidIndex();
        symbolHash = registeredSymbols[index];
        ThermoSlot storage s = thermometers[symbolHash];
        return (
            symbolHash,
            s.currentBand,
            s.currentPriceE8,
            s.currentVolatilityE8,
            s.halted
        );
    }

    function getSlotsCount() external view returns (uint256) {
        return registeredSymbols.length;
    }

    function symbolHashFromString(string calldata symbol) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(symbol));
    }

    function isRegistered(bytes32 symbolHash) external view returns (bool) {
        return thermometers[symbolHash].registeredAtBlock != 0;
    }

    function getTreasury() external view returns (address) {
        return treasury;
    }

    function getUpdater() external view returns (address) {
        return updater;
    }

    function getGuardian() external view returns (address) {
        return guardian;
    }

    function getPaused() external view returns (bool) {
        return platformPaused;
    }

    function getReportFeeWei() external view returns (uint256) {
        return reportFeeWei;
    }

    function getMaxHistoryLength() external view returns (uint256) {
        return maxHistoryLength;
    }

    function getWindowBlocks(bytes32 symbolHash) external view returns (uint256) {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        return thermometers[symbolHash].windowBlocks;
    }

    function getCooldownBlocks(bytes32 symbolHash) external view returns (uint256) {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        return thermometers[symbolHash].cooldownBlocks;
    }

    function getLastReportBlock(bytes32 symbolHash) external view returns (uint256) {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        return thermometers[symbolHash].lastReportBlock;
    }

    function getRegisteredAtBlock(bytes32 symbolHash) external view returns (uint256) {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        return thermometers[symbolHash].registeredAtBlock;
    }

    function getHistoryLength(bytes32 symbolHash) external view returns (uint256) {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        return thermometers[symbolHash].priceHistoryE8.length;
    }

    function getBandHistoryLength(bytes32 symbolHash) external view returns (uint256) {
        return _bandHistoryBlocks[symbolHash].length;
    }

    function multiGetCurrentBand(bytes32[] calldata symbolHashes) external view returns (uint8[] memory bands) {
        bands = new uint8[](symbolHashes.length);
        for (uint256 i; i < symbolHashes.length; ) {
            if (thermometers[symbolHashes[i]].registeredAtBlock != 0) {
                bands[i] = thermometers[symbolHashes[i]].currentBand;
            } else {
                bands[i] = 0;
            }
            unchecked { ++i; }
        }
    }

    function multiGetVolatilityE8(bytes32[] calldata symbolHashes) external view returns (uint256[] memory vols) {
        vols = new uint256[](symbolHashes.length);
        for (uint256 i; i < symbolHashes.length; ) {
            if (thermometers[symbolHashes[i]].registeredAtBlock != 0) {
                vols[i] = thermometers[symbolHashes[i]].currentVolatilityE8;
            }
            unchecked { ++i; }
        }
    }

    function multiGetPriceE8(bytes32[] calldata symbolHashes) external view returns (uint256[] memory prices) {
        prices = new uint256[](symbolHashes.length);
        for (uint256 i; i < symbolHashes.length; ) {
            if (thermometers[symbolHashes[i]].registeredAtBlock != 0) {
                prices[i] = thermometers[symbolHashes[i]].currentPriceE8;
            }
            unchecked { ++i; }
        }
    }

    function multiIsHalted(bytes32[] calldata symbolHashes) external view returns (bool[] memory halted) {
        halted = new bool[](symbolHashes.length);
        for (uint256 i; i < symbolHashes.length; ) {
            halted[i] = thermometers[symbolHashes[i]].halted;
            unchecked { ++i; }
        }
    }

    function getBandStats() external view returns (
        uint256 coldCount,
        uint256 mildCount,
        uint256 warmCount,
        uint256 hotCount,
        uint256 criticalCount
    ) {
        for (uint256 i; i < registeredSymbols.length; ) {
            uint8 b = thermometers[registeredSymbols[i]].currentBand;
            if (b == THRM_BAND_COLD) coldCount++;
            else if (b == THRM_BAND_MILD) mildCount++;
            else if (b == THRM_BAND_WARM) warmCount++;
            else if (b == THRM_BAND_HOT) hotCount++;
            else if (b == THRM_BAND_CRITICAL) criticalCount++;
            unchecked { ++i; }
        }
    }

    function getDomainSalt() external pure returns (uint256) {
        return THRM_DOMAIN_SALT;
    }

    function getMaxThermometers() external pure returns (uint256) {
        return THRM_MAX_THERMOMETERS;
    }

    function getMinWindowBlocks() external pure returns (uint256) {
        return THRM_MIN_WINDOW_BLOCKS;
    }

    function getMaxWindowBlocks() external pure returns (uint256) {
        return THRM_MAX_WINDOW_BLOCKS;
    }

    function getMaxBatchReport() external pure returns (uint256) {
        return THRM_MAX_BATCH_REPORT;
    }

    function getBpsBase() external pure returns (uint256) {
        return THRM_BPS_BASE;
    }

    function getMinPriceInWindow(bytes32 symbolHash) external view returns (uint256 priceE8, uint256 atBlock) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256[] storage p = s.priceHistoryE8;
        uint256[] storage b = s.blockHistory;
        uint256 w = s.windowBlocks;
        uint256 n = p.length;
        if (n == 0) return (0, 0);
        uint256 minP = type(uint256).max;
        uint256 minBlock;
        for (uint256 i = n; i > 0; ) {
            unchecked { --i; }
            if (b[n - 1] - b[i] > w) break;
            if (p[i] < minP) {
                minP = p[i];
                minBlock = b[i];
            }
        }
        return (minP == type(uint256).max ? 0 : minP, minBlock);
    }

    function getMaxPriceInWindow(bytes32 symbolHash) external view returns (uint256 priceE8, uint256 atBlock) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256[] storage p = s.priceHistoryE8;
        uint256[] storage b = s.blockHistory;
        uint256 w = s.windowBlocks;
        uint256 n = p.length;
        if (n == 0) return (0, 0);
        uint256 maxP;
        uint256 maxBlock;
        for (uint256 i = n; i > 0; ) {
            unchecked { --i; }
            if (b[n - 1] - b[i] > w) break;
            if (p[i] > maxP) {
                maxP = p[i];
                maxBlock = b[i];
            }
        }
        return (maxP, maxBlock);
    }

    function getPriceChangeBps(bytes32 symbolHash, uint256 fromBlock, uint256 toBlock) external view returns (
        int256 changeBps,
        bool fromFound,
        bool toFound
    ) {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        (uint256 pFrom, bool fromF) = getPriceAtBlock(symbolHash, fromBlock);
        (uint256 pTo, bool toF) = getPriceAtBlock(symbolHash, toBlock);
        fromFound = fromF;
        toFound = toF;
        if (!fromFound || !toFound || pFrom == 0 || pTo == 0) return (0, fromFound, toFound);
        if (pTo >= pFrom) {
            changeBps = int256((uint256(pTo - pFrom) * THRM_BPS_BASE) / pFrom);
        } else {
            changeBps = -int256((uint256(pFrom - pTo) * THRM_BPS_BASE) / pFrom);
        }
    }

    function getAveragePriceInWindow(bytes32 symbolHash) external view returns (uint256 avgE8, uint256 sampleCount) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256[] storage p = s.priceHistoryE8;
        uint256[] storage b = s.blockHistory;
        uint256 w = s.windowBlocks;
        uint256 n = p.length;
        if (n == 0) return (0, 0);
        uint256 sum;
        uint256 count;
        for (uint256 i = n; i > 0; ) {
            unchecked { --i; }
            if (b[n - 1] - b[i] > w) break;
            sum += p[i];
            count++;
        }
        if (count == 0) return (0, 0);
        return (sum / count, count);
    }

    function getMedianBand() external view returns (uint8) {
        if (registeredSymbols.length == 0) revert THRM_NoThermometers();
        uint256[] memory bandCounts = new uint256[](5);
        for (uint256 i; i < registeredSymbols.length; ) {
            uint8 b = thermometers[registeredSymbols[i]].currentBand;
            if (b <= 4) bandCounts[b]++;
            unchecked { ++i; }
        }
        uint256 half = registeredSymbols.length / 2;
        uint256 acc;
        for (uint8 j; j <= 4; ) {
            acc += bandCounts[j];
            if (acc > half) return j;
            unchecked { ++j; }
        }
        return 4;
    }

    function getHottestSymbol() external view returns (bytes32 symbolHash, uint8 band, uint256 volatilityE8) {
        if (registeredSymbols.length == 0) revert THRM_NoThermometers();
        bytes32 outSym;
        uint8 outBand;
        uint256 outVol;
        for (uint256 i; i < registeredSymbols.length; ) {
            ThermoSlot storage s = thermometers[registeredSymbols[i]];
            if (s.currentBand > outBand || (s.currentBand == outBand && s.currentVolatilityE8 > outVol)) {
                outSym = registeredSymbols[i];
                outBand = s.currentBand;
                outVol = s.currentVolatilityE8;
            }
            unchecked { ++i; }
        }
        return (outSym, outBand, outVol);
    }

    function getColdestSymbol() external view returns (bytes32 symbolHash, uint8 band, uint256 volatilityE8) {
        if (registeredSymbols.length == 0) revert THRM_NoThermometers();
        bytes32 outSym = registeredSymbols[0];
        uint8 outBand = thermometers[outSym].currentBand;
        uint256 outVol = thermometers[outSym].currentVolatilityE8;
        for (uint256 i = 1; i < registeredSymbols.length; ) {
            ThermoSlot storage s = thermometers[registeredSymbols[i]];
            if (s.currentBand < outBand || (s.currentBand == outBand && s.currentVolatilityE8 < outVol)) {
                outSym = registeredSymbols[i];
                outBand = s.currentBand;
                outVol = s.currentVolatilityE8;
            }
            unchecked { ++i; }
        }
        return (outSym, outBand, outVol);
    }

    function getTotalReportCount() external view returns (uint256) {
        uint256 total;
        for (uint256 i; i < registeredSymbols.length; ) {
            total += thermometers[registeredSymbols[i]].priceHistoryE8.length;
            unchecked { ++i; }
        }
        return total;
    }

    function getSymbolReportCount(bytes32 symbolHash) external view returns (uint256) {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        return thermometers[symbolHash].priceHistoryE8.length;
    }

    function getFirstPrice(bytes32 symbolHash) external view returns (uint256 priceE8, uint256 blockNum) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        if (s.priceHistoryE8.length == 0) return (0, 0);
        return (s.priceHistoryE8[0], s.blockHistory[0]);
    }

    function getPriceRange(bytes32 symbolHash) external view returns (uint256 minE8, uint256 maxE8) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256[] storage p = s.priceHistoryE8;
        uint256 len = p.length;
        if (len == 0) return (0, 0);
        minE8 = type(uint256).max;
        for (uint256 i; i < len; ) {
            if (p[i] < minE8) minE8 = p[i];
            if (p[i] > maxE8) maxE8 = p[i];
            unchecked { ++i; }
        }
        if (minE8 == type(uint256).max) minE8 = 0;
    }

    function getVolatilityTrend(bytes32 symbolHash, uint256 points) external view returns (int256 trendE8) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256 len = s.priceHistoryE8.length;
        if (len < 2 || points < 2) return 0;
        if (points > len) points = len;
        uint256 recentVol = _computeVolatilityE8(s);
        uint256 oldLen = len - points;
        uint256[] memory oldPrices = new uint256[](oldLen);
        uint256[] memory oldBlocks = new uint256[](oldLen);
        for (uint256 i; i < oldLen; ) {
            oldPrices[i] = s.priceHistoryE8[i];
            oldBlocks[i] = s.blockHistory[i];
            unchecked { ++i; }
        }
        uint256 sum;
        uint256 count;
        for (uint256 i = oldLen - 1; i > 0; ) {
            if (oldBlocks[oldLen - 1] - oldBlocks[i - 1] > s.windowBlocks) break;
            uint256 pCur = oldPrices[i];
            uint256 pPrev = oldPrices[i - 1];
            if (pPrev == 0) { unchecked { --i; } continue; }
            uint256 ch = (pCur > pPrev) ? ((pCur - pPrev) * THRM_BPS_BASE) / pPrev : ((pPrev - pCur) * THRM_BPS_BASE) / pPrev;
            sum += ch;
            count++;
            unchecked { --i; }
        }
        uint256 oldVolBps = count == 0 ? 0 : sum / count;
        uint256 recentVolBps = (recentVol * THRM_BPS_BASE) / 1e8;
        if (recentVolBps >= oldVolBps) return int256(uint256((recentVolBps - oldVolBps) * 1e8 / THRM_BPS_BASE));
        return -int256(uint256((oldVolBps - recentVolBps) * 1e8 / THRM_BPS_BASE));
    }

    function getBandDistribution() external view returns (
        uint256 cold,
        uint256 mild,
        uint256 warm,
        uint256 hot,
        uint256 critical
    ) {
        for (uint256 i; i < registeredSymbols.length; ) {
            uint8 b = thermometers[registeredSymbols[i]].currentBand;
            if (b == 0) cold++;
            else if (b == 1) mild++;
            else if (b == 2) warm++;
            else if (b == 3) hot++;
            else critical++;
            unchecked { ++i; }
        }
    }

    function getWeightedAverageBand() external view returns (uint256 weightedE4) {
        if (registeredSymbols.length == 0) revert THRM_NoThermometers();
        uint256 sum;
        for (uint256 i; i < registeredSymbols.length; ) {
            sum += uint256(thermometers[registeredSymbols[i]].currentBand) * 1e4;
            unchecked { ++i; }
        }
        return sum / registeredSymbols.length;
    }

    function getAlertsSummary() external view returns (
        uint256 hotOrCriticalCount,
        uint256 haltedCount,
        uint256 staleCount,
        uint256 blocksSinceLastReport
    ) {
        uint256 lastBlock;
        for (uint256 i; i < registeredSymbols.length; ) {
            ThermoSlot storage s = thermometers[registeredSymbols[i]];
            if (s.currentBand >= THRM_BAND_HOT) hotOrCriticalCount++;
            if (s.halted) haltedCount++;
            if (s.lastReportBlock > lastBlock) lastBlock = s.lastReportBlock;
            unchecked { ++i; }
        }
        blocksSinceLastReport = lastBlock == 0 ? 0 : block.number - lastBlock;
        if (blocksSinceLastReport > 100) staleCount = 1;
    }

    function getFullSlot(bytes32 symbolHash) external view returns (
        bytes32 symHash,
        uint256 windowBlocks,
        uint256 cooldownBlocks,
        uint256 lastReportBlock,
        uint256 historyLen,
        uint8 currentBand,
        uint256 currentVolatilityE8,
        uint256 currentPriceE8,
        bool halted,
        uint256 registeredAtBlock
    ) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        return (
            s.symbolHash,
            s.windowBlocks,
            s.cooldownBlocks,
            s.lastReportBlock,
            s.priceHistoryE8.length,
            s.currentBand,
            s.currentVolatilityE8,
            s.currentPriceE8,
            s.halted,
            s.registeredAtBlock
        );
    }

    function getPaginatedSymbols(uint256 offset, uint256 limit) external view returns (bytes32[] memory out) {
        uint256 n = registeredSymbols.length;
        if (offset >= n) return new bytes32[](0);
        if (limit == 0 || offset + limit > n) limit = n - offset;
        out = new bytes32[](limit);
        for (uint256 i; i < limit; ) {
            out[i] = registeredSymbols[offset + i];
            unchecked { ++i; }
        }
    }

    function getSlotsPaginated(uint256 offset, uint256 limit) external view returns (
        bytes32[] memory symbolHashes,
        uint8[] memory bands,
        uint256[] memory pricesE8,
        uint256[] memory volatilitiesE8,
        bool[] memory haltedFlags
    ) {
        uint256 n = registeredSymbols.length;
        if (n == 0) return (new bytes32[](0), new uint8[](0), new uint256[](0), new uint256[](0), new bool[](0));
        if (offset >= n) return (new bytes32[](0), new uint8[](0), new uint256[](0), new uint256[](0), new bool[](0));
        if (limit == 0 || offset + limit > n) limit = n - offset;
        symbolHashes = new bytes32[](limit);
        bands = new uint8[](limit);
        pricesE8 = new uint256[](limit);
        volatilitiesE8 = new uint256[](limit);
        haltedFlags = new bool[](limit);
        for (uint256 i; i < limit; ) {
            bytes32 sh = registeredSymbols[offset + i];
            ThermoSlot storage s = thermometers[sh];
            symbolHashes[i] = sh;
            bands[i] = s.currentBand;
            pricesE8[i] = s.currentPriceE8;
            volatilitiesE8[i] = s.currentVolatilityE8;
            haltedFlags[i] = s.halted;
            unchecked { ++i; }
        }
    }

    function getBlockNumbersForSymbol(bytes32 symbolHash, uint256 offset, uint256 limit) external view returns (uint256[] memory blocks) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256 len = s.blockHistory.length;
        if (offset >= len) return new uint256[](0);
        if (limit == 0 || offset + limit > len) limit = len - offset;
        blocks = new uint256[](limit);
        for (uint256 i; i < limit; ) {
            blocks[i] = s.blockHistory[offset + i];
            unchecked { ++i; }
        }
    }

    function getPricesForBlocks(bytes32 symbolHash, uint256[] calldata blockNums) external view returns (uint256[] memory pricesE8, bool[] memory found) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256 n = blockNums.length;
        pricesE8 = new uint256[](n);
        found = new bool[](n);
        uint256[] storage blks = s.blockHistory;
        uint256[] storage prcs = s.priceHistoryE8;
        for (uint256 i; i < n; ) {
            for (uint256 j = blks.length; j > 0; ) {
                unchecked { --j; }
                if (blks[j] <= blockNums[i]) {
                    pricesE8[i] = prcs[j];
                    found[i] = true;
                    break;
                }
            }
            unchecked { ++i; }
        }
    }

    function getLastNBandChanges(bytes32 symbolHash, uint256 n) external view returns (uint8[] memory bands, uint256[] memory blocks) {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256[] storage blks = _bandHistoryBlocks[symbolHash];
        uint8[] storage bnds = _bandHistoryValues[symbolHash];
        uint256 len = blks.length;
        if (n == 0 || n > len) n = len;
        uint256 start = len - n;
        bands = new uint8[](n);
        blocks = new uint256[](n);
        for (uint256 i; i < n; ) {
            bands[i] = bnds[start + i];
            blocks[i] = blks[start + i];
            unchecked { ++i; }
        }
    }

    function getVolatilityAtReportIndex(bytes32 symbolHash, uint256 reportIndex) external view returns (uint256 volE8) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256 len = s.priceHistoryE8.length;
        if (reportIndex >= len) revert THRM_InvalidIndex();
        uint256 w = s.windowBlocks;
        uint256[] storage p = s.priceHistoryE8;
        uint256[] storage b = s.blockHistory;
        uint256 sum;
        uint256 count;
        for (uint256 i = reportIndex; i > 0; ) {
            unchecked { --i; }
            if (b[reportIndex] - b[i] > w) break;
            uint256 pCur = p[i];
            uint256 pPrev = i == 0 ? pCur : p[i - 1];
            if (pPrev != 0 && i > 0) {
                uint256 ch = (pCur > pPrev) ? ((pCur - pPrev) * THRM_BPS_BASE) / pPrev : ((pPrev - pCur) * THRM_BPS_BASE) / pPrev;
                sum += ch;
                count++;
            }
        }
        if (count == 0) return 0;
        return (sum * 1e8) / (count * THRM_BPS_BASE);
    }

    function getSymbolHashAtIndex(uint256 index) external view returns (bytes32) {
        if (index >= registeredSymbols.length) revert THRM_InvalidIndex();
        return registeredSymbols[index];
    }

    function getThermometerCount() external view returns (uint256) {
        return thermometerCount;
    }

    function getOwner() external view returns (address) {
        return owner;
    }

    function supportsSymbol(bytes32 symbolHash) external view returns (bool) {
        return thermometers[symbolHash].registeredAtBlock != 0;
    }

    function getPriceHistoryLength(bytes32 symbolHash) external view returns (uint256) {
        return thermometers[symbolHash].priceHistoryE8.length;
    }

    function getBandAtBlock(bytes32 symbolHash, uint256 blockNum) external view returns (uint8 band, bool found) {
        uint256[] storage blks = _bandHistoryBlocks[symbolHash];
        uint8[] storage bnds = _bandHistoryValues[symbolHash];
        for (uint256 i = blks.length; i > 0; ) {
            unchecked { --i; }
            if (blks[i] <= blockNum) {
                return (bnds[i], true);
            }
        }
        return (0, false);
    }

    function getCumulativeBandTime(bytes32 symbolHash, uint8 band) external view returns (uint256 blocksInBand) {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        if (band > THRM_BAND_CRITICAL) revert THRM_InvalidBand();
        uint256[] storage blks = _bandHistoryBlocks[symbolHash];
        uint8[] storage bnds = _bandHistoryValues[symbolHash];
        for (uint256 i; i < blks.length; ) {
            if (bnds[i] == band) {
                if (i + 1 < blks.length) {
                    blocksInBand += blks[i + 1] - blks[i];
                } else {
                    blocksInBand += block.number - blks[i];
                }
            }
            unchecked { ++i; }
        }
    }

    function getTreasuryBalance() external view returns (uint256) {
        return treasury.balance;
    }

    function getChainId() external view returns (uint256) {
        return block.chainid;
    }

    function getBlockNumber() external view returns (uint256) {
        return block.number;
    }

    function getTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function getVersionDomain() external pure returns (bytes32) {
        return THRM_GENESIS_DOMAIN;
    }

    function getConstants() external pure returns (
        uint256 bpsBase,
        uint256 maxThermometers,
        uint256 minWindowBlocks,
        uint256 maxWindowBlocks,
        uint256 maxHistoryLen,
        uint256 maxBatchReport
    ) {
        return (
            THRM_BPS_BASE,
            THRM_MAX_THERMOMETERS,
            THRM_MIN_WINDOW_BLOCKS,
            THRM_MAX_WINDOW_BLOCKS,
            THRM_MAX_HISTORY_LEN,
            THRM_MAX_BATCH_REPORT
        );
    }

    function getBandNames() external pure returns (
        string memory coldName,
        string memory mildName,
        string memory warmName,
        string memory hotName,
        string memory criticalName
    ) {
        return ("cold", "mild", "warm", "hot", "critical");
    }

    function getAggregateVolatilityE8() external view returns (uint256) {
        if (registeredSymbols.length == 0) revert THRM_NoThermometers();
        uint256 sum;
        for (uint256 i; i < registeredSymbols.length; ) {
            sum += thermometers[registeredSymbols[i]].currentVolatilityE8;
            unchecked { ++i; }
        }
        return sum / registeredSymbols.length;
    }

    function getAggregatePriceE8() external view returns (uint256) {
        if (registeredSymbols.length == 0) revert THRM_NoThermometers();
        uint256 sum;
        uint256 count;
        for (uint256 i; i < registeredSymbols.length; ) {
            uint256 p = thermometers[registeredSymbols[i]].currentPriceE8;
            if (p > 0) { sum += p; count++; }
            unchecked { ++i; }
        }
        return count == 0 ? 0 : sum / count;
    }

    function hasAnyHotOrCritical() external view returns (bool) {
        for (uint256 i; i < registeredSymbols.length; ) {
            if (thermometers[registeredSymbols[i]].currentBand >= THRM_BAND_HOT) return true;
            unchecked { ++i; }
        }
        return false;
    }

    function hasAnyHalted() external view returns (bool) {
        for (uint256 i; i < registeredSymbols.length; ) {
            if (thermometers[registeredSymbols[i]].halted) return true;
            unchecked { ++i; }
        }
        return false;
    }

    function getHaltedSymbols() external view returns (bytes32[] memory) {
        uint256 count;
        for (uint256 i; i < registeredSymbols.length; ) {
            if (thermometers[registeredSymbols[i]].halted) count++;
            unchecked { ++i; }
        }
        bytes32[] memory out = new bytes32[](count);
        count = 0;
        for (uint256 i; i < registeredSymbols.length; ) {
            if (thermometers[registeredSymbols[i]].halted) {
                out[count] = registeredSymbols[i];
                count++;
            }
            unchecked { ++i; }
        }
        return out;
    }

    function getHotOrCriticalSymbols() external view returns (bytes32[] memory) {
        uint256 count;
        for (uint256 i; i < registeredSymbols.length; ) {
            if (thermometers[registeredSymbols[i]].currentBand >= THRM_BAND_HOT) count++;
            unchecked { ++i; }
        }
        bytes32[] memory out = new bytes32[](count);
        count = 0;
        for (uint256 i; i < registeredSymbols.length; ) {
            if (thermometers[registeredSymbols[i]].currentBand >= THRM_BAND_HOT) {
                out[count] = registeredSymbols[i];
                count++;
            }
            unchecked { ++i; }
        }
        return out;
    }

    function getStaleSymbols(uint256 maxBlocksSinceReport) external view returns (bytes32[] memory) {
        uint256 count;
        for (uint256 i; i < registeredSymbols.length; ) {
            ThermoSlot storage s = thermometers[registeredSymbols[i]];
            if (s.lastReportBlock != 0 && block.number - s.lastReportBlock > maxBlocksSinceReport) count++;
            unchecked { ++i; }
        }
        bytes32[] memory out = new bytes32[](count);
        count = 0;
        for (uint256 i; i < registeredSymbols.length; ) {
            ThermoSlot storage s = thermometers[registeredSymbols[i]];
            if (s.lastReportBlock != 0 && block.number - s.lastReportBlock > maxBlocksSinceReport) {
                out[count] = registeredSymbols[i];
                count++;
            }
            unchecked { ++i; }
        }
        return out;
    }

    function getConfigSnapshot() external view returns (
        address ownerAddr,
        address treasuryAddr,
        address guardianAddr,
        address updaterAddr,
        uint256 deployBlk,
        uint256 coldBpsVal,
        uint256 mildBpsVal,
        uint256 warmBpsVal,
        uint256 hotBpsVal,
        uint256 reportFee,
        uint256 maxHistLen,
        bool paused
    ) {
        return (
            owner,
            treasury,
            guardian,
            updater,
            deployBlock,
            coldBps,
            mildBps,
            warmBps,
            hotBps,
            reportFeeWei,
            maxHistoryLength,
            platformPaused
        );
    }

    function getPriceSpreadE8(bytes32 symbolHash) external view returns (uint256 spreadE8) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        (uint256 minP,) = getMinPriceInWindow(symbolHash);
        (uint256 maxP,) = getMaxPriceInWindow(symbolHash);
        if (minP == 0 && maxP == 0) return 0;
        if (minP == 0) return maxP;
        return maxP - minP;
    }

    function getPriceSpreadBps(bytes32 symbolHash) external view returns (uint256 spreadBps) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        (uint256 minP,) = getMinPriceInWindow(symbolHash);
        (uint256 maxP,) = getMaxPriceInWindow(symbolHash);
        if (minP == 0 || maxP == 0) return 0;
        return ((maxP - minP) * THRM_BPS_BASE) / minP;
    }

    function getNthPrice(bytes32 symbolHash, uint256 n) external view returns (uint256 priceE8, uint256 blockNum) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256 len = s.priceHistoryE8.length;
        if (n >= len) revert THRM_InvalidIndex();
        return (s.priceHistoryE8[n], s.blockHistory[n]);
    }

    function getNthBand(bytes32 symbolHash, uint256 n) external view returns (uint8 band, uint256 blockNum) {
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256 len = _bandHistoryBlocks[symbolHash].length;
        if (n >= len) revert THRM_InvalidIndex();
        return (_bandHistoryValues[symbolHash][n], _bandHistoryBlocks[symbolHash][n]);
    }

    function getTimeInCurrentBand(bytes32 symbolHash) external view returns (uint256 blocksInCurrentBand) {
        uint256[] storage blks = _bandHistoryBlocks[symbolHash];
        if (blks.length == 0) return 0;
        return block.number - blks[blks.length - 1];
    }

    function getPreviousBand(bytes32 symbolHash) external view returns (uint8 band, bool hasPrevious) {
        uint8[] storage bnds = _bandHistoryValues[symbolHash];
        if (bnds.length < 2) return (0, false);
        return (bnds[bnds.length - 2], true);
    }

    function getBandChangeCount(bytes32 symbolHash) external view returns (uint256) {
        uint8[] storage bnds = _bandHistoryValues[symbolHash];
        if (bnds.length < 2) return 0;
        uint256 count;
        for (uint256 i = 1; i < bnds.length; ) {
            if (bnds[i] != bnds[i - 1]) count++;
            unchecked { ++i; }
        }
        return count;
    }

    function getMaxVolatilityE8Seen(bytes32 symbolHash) external view returns (uint256 maxVolE8) {
        uint8[] storage bnds = _bandHistoryValues[symbolHash];
        uint256[] storage blks = _bandHistoryBlocks[symbolHash];
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        ThermoSlot storage s = thermometers[symbolHash];
        uint256 len = s.priceHistoryE8.length;
        for (uint256 endIdx = 1; endIdx < len; ) {
            uint256 sum;
            uint256 count;
            for (uint256 i = endIdx; i > 0; ) {
                unchecked { --i; }
                if (s.blockHistory[endIdx] - s.blockHistory[i] > s.windowBlocks) break;
                uint256 pCur = s.priceHistoryE8[i];
                uint256 pPrev = i == 0 ? pCur : s.priceHistoryE8[i - 1];
                if (pPrev != 0 && i > 0) {
                    uint256 ch = (pCur > pPrev) ? ((pCur - pPrev) * THRM_BPS_BASE) / pPrev : ((pPrev - pCur) * THRM_BPS_BASE) / pPrev;
                    sum += ch;
                    count++;
                }
            }
            uint256 volBps = count == 0 ? 0 : sum / count;
            uint256 volE8 = (volBps * 1e8) / THRM_BPS_BASE;
            if (volE8 > maxVolE8) maxVolE8 = volE8;
            unchecked { ++endIdx; }
        }
    }

    function getMinVolatilityE8InWindow(bytes32 symbolHash) external view returns (uint256 minVolE8) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256 len = s.priceHistoryE8.length;
        minVolE8 = type(uint256).max;
        for (uint256 endIdx = 1; endIdx < len; ) {
            uint256 sum;
            uint256 count;
            for (uint256 i = endIdx; i > 0; ) {
                unchecked { --i; }
                if (s.blockHistory[endIdx] - s.blockHistory[i] > s.windowBlocks) break;
                uint256 pCur = s.priceHistoryE8[i];
                uint256 pPrev = i == 0 ? pCur : s.priceHistoryE8[i - 1];
                if (pPrev != 0 && i > 0) {
                    uint256 ch = (pCur > pPrev) ? ((pCur - pPrev) * THRM_BPS_BASE) / pPrev : ((pPrev - pCur) * THRM_BPS_BASE) / pPrev;
                    sum += ch;
                    count++;
                }
            }
            uint256 volBps = count == 0 ? 0 : sum / count;
            uint256 volE8 = (volBps * 1e8) / THRM_BPS_BASE;
            if (volE8 < minVolE8) minVolE8 = volE8;
            unchecked { ++endIdx; }
        }
        if (minVolE8 == type(uint256).max) minVolE8 = 0;
    }

    function getSymbolsByVolatilityDesc() external view returns (bytes32[] memory symbolHashes, uint256[] memory volatilitiesE8) {
        uint256 n = registeredSymbols.length;
        if (n == 0) revert THRM_NoThermometers();
        symbolHashes = new bytes32[](n);
        volatilitiesE8 = new uint256[](n);
        for (uint256 i; i < n; ) {
            symbolHashes[i] = registeredSymbols[i];
            volatilitiesE8[i] = thermometers[registeredSymbols[i]].currentVolatilityE8;
            unchecked { ++i; }
        }
        for (uint256 i; i < n; ) {
            for (uint256 j = i + 1; j < n; ) {
                if (volatilitiesE8[j] > volatilitiesE8[i]) {
                    bytes32 tSym = symbolHashes[i];
                    symbolHashes[i] = symbolHashes[j];
                    symbolHashes[j] = tSym;
                    uint256 tVol = volatilitiesE8[i];
                    volatilitiesE8[i] = volatilitiesE8[j];
                    volatilitiesE8[j] = tVol;
                }
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }
    }

    function getSymbolsByBandAsc() external view returns (bytes32[] memory symbolHashes, uint8[] memory bands) {
        uint256 n = registeredSymbols.length;
        if (n == 0) revert THRM_NoThermometers();
        symbolHashes = new bytes32[](n);
        bands = new uint8[](n);
        for (uint256 i; i < n; ) {
            symbolHashes[i] = registeredSymbols[i];
            bands[i] = thermometers[registeredSymbols[i]].currentBand;
            unchecked { ++i; }
        }
        for (uint256 i; i < n; ) {
            for (uint256 j = i + 1; j < n; ) {
                if (bands[j] < bands[i] || (bands[j] == bands[i] && symbolHashes[j] < symbolHashes[i])) {
                    bytes32 tSym = symbolHashes[i];
                    symbolHashes[i] = symbolHashes[j];
                    symbolHashes[j] = tSym;
                    uint8 tBand = bands[i];
                    bands[i] = bands[j];
                    bands[j] = tBand;
                }
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }
    }

    function getBlocksSinceFirstReport(bytes32 symbolHash) external view returns (uint256) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        if (s.blockHistory.length == 0) return 0;
        return block.number - s.blockHistory[0];
    }

    function getBlocksSinceLastReport(bytes32 symbolHash) external view returns (uint256) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        if (s.lastReportBlock == 0) return type(uint256).max;
        return block.number - s.lastReportBlock;
    }

    function isStale(bytes32 symbolHash, uint256 maxBlocks) external view returns (bool) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        if (s.lastReportBlock == 0) return true;
        return block.number - s.lastReportBlock > maxBlocks;
    }

    function getReportFrequencyEstimate(bytes32 symbolHash) external view returns (uint256 avgBlocksBetweenReports) {
        uint256[] storage blks = thermometers[symbolHash].blockHistory;
        if (thermometers[symbolHash].registeredAtBlock == 0) revert THRM_SymbolNotFound();
        if (blks.length < 2) return 0;
        uint256 totalGap;
        for (uint256 i = 1; i < blks.length; ) {
            totalGap += blks[i] - blks[i - 1];
            unchecked { ++i; }
        }
        return totalGap / (blks.length - 1);
    }

    function getPercentilePriceE8(bytes32 symbolHash, uint256 percentileBps) external view returns (uint256 priceE8) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        uint256 len = s.priceHistoryE8.length;
        if (len == 0) return 0;
        if (percentileBps > THRM_BPS_BASE) percentileBps = THRM_BPS_BASE;
        uint256[] memory copy = new uint256[](len);
        for (uint256 i; i < len; ) {
            copy[i] = s.priceHistoryE8[i];
            unchecked { ++i; }
        }
        for (uint256 i; i < len; ) {
            for (uint256 j = i + 1; j < len; ) {
                if (copy[j] < copy[i]) {
                    uint256 t = copy[i];
                    copy[i] = copy[j];
                    copy[j] = t;
                }
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }
        uint256 idx = (len * percentileBps) / THRM_BPS_BASE;
        if (idx >= len) idx = len - 1;
        return copy[idx];
    }

    function getMedianPriceE8(bytes32 symbolHash) external view returns (uint256) {
        return getPercentilePriceE8(symbolHash, 5000);
    }

    function getSummaryForSymbol(bytes32 symbolHash) external view returns (
        uint256 currentPriceE8,
        uint256 currentVolatilityE8,
        uint8 currentBand,
        uint256 minPriceE8,
        uint256 maxPriceE8,
        uint256 historyLength,
        bool halted,
        uint256 lastReportBlock
    ) {
        ThermoSlot storage s = thermometers[symbolHash];
        if (s.registeredAtBlock == 0) revert THRM_SymbolNotFound();
        (uint256 minP,) = getMinPriceInWindow(symbolHash);
        (uint256 maxP,) = getMaxPriceInWindow(symbolHash);
        return (
            s.currentPriceE8,
            s.currentVolatilityE8,
            s.currentBand,
            minP,
            maxP,
            s.priceHistoryE8.length,
            s.halted,
            s.lastReportBlock
        );
    }

    function getMultiSummary(bytes32[] calldata symbolHashes) external view returns (
