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
