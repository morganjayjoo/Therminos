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
