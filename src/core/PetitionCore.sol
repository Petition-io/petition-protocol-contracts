// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "../reputation/ReputationEngine.sol";
import "../interfaces/IBadgeSystem.sol";
import "../governance/EndorsementRegistry.sol";
import "../interfaces/governance/IVotingPower.sol";
import "../libraries/PetitionCoreViewsLib.sol";
import "../libraries/PetitionCoreSplitLib.sol";
import "../libraries/PetitionCorePriceLib.sol";
import "../libraries/PetitionCoreReputationLib.sol";
import "../libraries/PetitionCoreTypeLib.sol";
import "../libraries/PetitionCoreMetaLib.sol";
import "../interfaces/core/IPetitionCoreCampaignReader.sol";
import "../interfaces/relay/IPetitionCoreRelayTarget.sol";
import "../types/CampaignTypes.sol";

import {IBeneficiaryRegistry} from "../interfaces/governance/IBeneficiaryRegistry.sol";

interface IDAORegistryLike {
    function isDAOMember(address user) external view returns (bool);
}

interface IQuadraticFunding {
    function receiveFees(uint256 qfAmount, uint256 treasuryAmount, uint256 devAmount) external payable;
    function reportCampaignData(
        uint256 campaignId,
        uint256 signatureCount,
        uint256 newContribution,
        address contributor,
        address beneficiary
    ) external;
}

interface IProfileRegistry {
    function publicSign(uint256 campaignId) external;
    function signForCampaignAuthorized(uint256 campaignId, address signer) external;
    function signForCampaignAuthorizedWithShare(
        uint256 campaignId,
        address signer,
        string calldata shareArTxId,
        string calldata shareContentHash
    ) external;
    function shareSignatureForCampaign(
        uint256 campaignId,
        string calldata shareArTxId,
        string calldata shareContentHash
    ) external;
    function hasSigned(uint256 campaignId, address user) external view returns (bool);
    function hasSharedSignature(uint256 campaignId, address signer) external view returns (bool);
    function getSignatureCount(uint256 campaignId) external view returns (uint256);
    function getActiveSignatureVersion(address user) external view returns (string memory, string memory, uint64, bool);
}

contract PetitionCore is ReentrancyGuard, Pausable, Ownable, EIP712, IPetitionCoreRelayTarget {
    using ECDSA for bytes32;

    struct Contribution {
        address contributor;
        uint256 amount;
        uint256 timestamp;
        uint256 campaignId;
    }

    struct ReceiptMeta {
        address donor;
        uint256 campaignId;
        address beneficiary;
        uint256 contributionWei;
        uint256 usdAmountCents;
        int256 ethUsdPrice;
        uint8 priceDecimals;
        uint256 timestamp;
        uint256 chainId;
        uint256 contributionId;
        string arTxId;
        string contentHash;
    }

    struct ContribCtx {
        uint256 campaignId;
        address sender;
        uint256 value;
        uint256 workingWei;
        uint256 contributionId;
    }

    struct CreateCampaignParams {
        address creator;
        bool isDao;
        address beneficiary;
        address asset;
        uint256 targetAmount;
        uint256 durationInDays;
        string arweaveTxId;
        bytes32 contentHash;
        bytes signature;
        PetitionType petitionType;
    }

    struct WithdrawalRecord {
        uint256 amount;
        uint64 timestamp;
        address beneficiary;
        bool finalized; // true when this withdrawal also ended the campaign
        string arweaveTxId; // Arweave pointer to the off-chain withdrawal/history JSON
        bytes32 contentHash; // hash of the Arweave JSON for integrity
    }

    uint256 public constant BENEFICIARY_FEE_BASIS_POINTS = 9000;
    uint256 public constant QF_FEE_BASIS_POINTS = 500;
    uint256 public constant TREASURY_FEE_BASIS_POINTS = 250;
    uint256 public constant DEV_FEE_BASIS_POINTS = 250;
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    uint256 private constant PAGE_SIZE = 30;

    uint256 public constant DAO_BENEFICIARY_BPS = 8500; // 85%
    uint256 public constant DAO_QF_BPS          = 500;  // 5%
    uint256 public constant DAO_CREATOR_BPS     = 500;  // 5%
    uint256 public constant DAO_DEV_BPS         = 250;  // 2.5%
    uint256 public constant POL_BPS             = 250;  // 2.5%

    uint256 public constant SIGN_FEE_DAO_MEMBER_CENTS = 15;
    uint256 public constant SIGN_FEE_NON_DAO_MEMBER_CENTS = 30;

    uint256 public activeCampaignCount;

    IQuadraticFunding public quadraticFundingContract;
    IProfileRegistry public profileRegistry;
    AggregatorV3Interface public priceFeed;
    ReputationEngine public reputationEngine;
    IBadgeSystem public badgeSystem;
    EndorsementRegistry public endorsementRegistry;
    IDAORegistryLike public daoRegistry;
    IVotingPower public votingPower;
    IBeneficiaryRegistry public beneficiaryRegistry;

    uint256 public nextCampaignId;
    uint256 public nextContributionId;

    mapping(uint256 => Campaign) public campaigns;
    mapping(uint256 => uint256[]) public campaignContributions;
    mapping(uint256 => Contribution) public contributions;
    mapping(address => uint256[]) public userCampaigns;
    mapping(address => uint256[]) public userContributions;
    mapping(uint256 => mapping(address => bool)) public hasContributed;
    mapping(uint256 => mapping(address => uint256)) public contributionAmounts;

    /// @dev Cumulative beneficiary funds already withdrawn per campaign.
    mapping(uint256 => uint256) public withdrawnAmount;
    /// @dev Full withdrawal history per campaign.
    mapping(uint256 => WithdrawalRecord[]) private _campaignWithdrawals;

    /// @dev Lens post id for per-petition comments (set once by creator while active).
    ///      Frontend creates one Lens post per campaign, then links it here; comments on that post
    ///      are fetched via Lens API for the petition page.
    mapping(uint256 => bytes32) public lensPostIds;

    /// @dev Platform-wide Lens group for petition discussion posts (set by owner).
    bytes32 public lensGroupId;

    uint256[] private _campaignsWithDeadlines;
    mapping(uint256 => bool) private _inDeadlineList;

    uint256 public nextReceiptNo;
    mapping(uint256 => ReceiptMeta) private _receipts;
    mapping(address => uint256[]) private _userReceiptNos;
    mapping(address => uint256) public daoCreatorRewardBalance;
    uint256 public totalDaoCreatorRewardsPending;
    address public governanceExecutor;

    event CampaignCreatedLite(
        uint256 indexed campaignId,
        address indexed creator,
        address indexed beneficiary,
        address asset,
        uint256 targetAmount,
        uint256 deadline,
        string arweaveTxId,
        bytes32 contentHash,
        PetitionType petitionType,
        bool isDaoCampaign
    );

    event CampaignParamsUpdated(uint256 indexed campaignId, uint256 targetAmount, uint256 deadline);
    event CampaignMetadataUpdated(uint256 indexed campaignId, string arweaveTxId, bytes32 contentHash);
    event CampaignStatusChanged(uint256 indexed campaignId, bool isActive);
    event ContributionMade(uint256 indexed campaignId, uint256 indexed contributionId, address indexed contributor, uint256 amount);
    event FundsWithdrawn(uint256 indexed campaignId, address indexed beneficiary, uint256 amount);
    event CampaignWithdrawalRecorded(
        uint256 indexed campaignId,
        address indexed beneficiary,
        uint256 amount,
        bool finalized,
        uint256 recordIndex,
        uint256 totalWithdrawn,
        string arweaveTxId,
        bytes32 contentHash
    );
    event FeesDistributed(uint256 indexed campaignId, uint256 qfAmount, uint256 treasuryAmount, uint256 devAmount);
    event QFContractUpdated(address indexed newQFContract);
    event ProfileRegistryUpdated(address indexed newProfileRegistry);
    event CampaignAutoDeactivated(uint256 indexed campaignId, uint256 at);
    event SignatureAddedLight(uint256 indexed campaignId, address indexed signer, string message);

    event ContributionReceipt(
        uint256 indexed receiptNo,
        address indexed donor,
        uint256 indexed campaignId,
        address beneficiary,
        uint256 contributionWei,
        uint256 usdAmountCents,
        int256 ethUsdPrice,
        uint8 priceDecimals,
        uint256 chainId,
        uint256 timestamp
    );

    event ReceiptDocumentSaved(uint256 indexed receiptNo, address indexed donor, string arTxId, string contentHash);

    event GovernanceExecutorUpdated(address indexed governanceExecutor);
    event ReputationEngineUpdated(address indexed reputationEngine);
    event BadgeSystemUpdated(address indexed badgeSystem);
    event DaoRegistryUpdated(address indexed daoRegistry);
    event VotingPowerUpdated(address indexed votingPower);
    event BeneficiaryRegistryUpdated(address indexed beneficiaryRegistry);
    event EndorsementRegistryUpdated(address indexed endorsementRegistry);
    event EmergencyWithdrawal(address indexed receiver, uint256 amount);

    event LensPostLinked(
        uint256 indexed campaignId,
        bytes32 indexed lensPostId,
        address indexed creator
    );

    event LensGroupIdSet(bytes32 indexed lensGroupId, address indexed setter);

    event DaoCampaignCreatorRewardAccrued(
        uint256 indexed campaignId,
        address indexed creator,
        uint256 amount
    );

    event DaoCampaignCreatorRewardClaimed(
        address indexed creator,
        uint256 amount
    );

    error PetitionCore__CampaignNotFound();
    error PetitionCore__CampaignInactive();
    error PetitionCore__CampaignExpired();
    error PetitionCore__OnlyCampaignCreator();
    error PetitionCore__OnlyBeneficiary();
    error PetitionCore__InvalidTargetAmount();
    error PetitionCore__InvalidDeadline();
    error PetitionCore__ZeroContribution();
    error PetitionCore__AlreadyContributed();
    error PetitionCore__NoFundsToWithdraw();
    error PetitionCore__FundsAlreadyWithdrawn();
    error PetitionCore__WithdrawalFailed();
    error PetitionCore__CampaignStillActive();
    error PetitionCore__QFContractNotSet(); 
    error PetitionCore__InvalidQFContract();
    error PetitionCore__InsufficientSignatureFee();
    error PetitionCore__InvalidPriceFeedData();
    error PetitionCore__ProfileNotSet();
    error PetitionCore__NotReceiptOwner();
    error PetitionCore__ReceiptNotFound();
    error PetitionCore__InvalidAsset();
    error PetitionCore__InvalidAddress();
    error PetitionCore__InvalidArweavePointer();
    error PetitionCore__OnlyDAOMember();
    error PetitionCore__NoCreatorRewards();
    error PetitionCore__CreatorRewardTransferFailed();
    error PetitionCore__NoFundsAvailableForWithdrawal();
    error PetitionCore__LensPostAlreadySet();
    error PetitionCore__InvalidLensPostId();
    error PetitionCore__InvalidLensGroupId();
    error PetitionCore__OnlyRelayExecutor();
    error PetitionCore__RefundFailed();
    error PetitionCore__UnauthorizedCaller();

    event RelayExecutorUpdated(address indexed relayExecutor);

    address public relayExecutor;

    modifier campaignExists(uint256 _campaignId) {
        if (_campaignId >= nextCampaignId) revert PetitionCore__CampaignNotFound();
        _;
    }

    modifier onlyCampaignCreator(uint256 _campaignId) {
        if (campaigns[_campaignId].creator != msg.sender) revert PetitionCore__OnlyCampaignCreator();
        _;
    }

    modifier campaignActive(uint256 _campaignId) {
        _requireCampaignActive(_campaignId);
        _;
    }

    function _requireCampaignActive(uint256 _campaignId) internal {
        Campaign storage c = campaigns[_campaignId];
        if (!c.isActive) revert PetitionCore__CampaignInactive();
        if (c.deadline != 0 && block.timestamp > c.deadline) {
            _autoDeactivateIfExpired(_campaignId);
            revert PetitionCore__CampaignExpired();
        }
    }

    modifier onlyGovernance() {
        if (msg.sender != governanceExecutor) revert PetitionCore__UnauthorizedCaller();
        _;
    }

    modifier onlyRelayExecutor() {
        if (msg.sender != relayExecutor) revert PetitionCore__OnlyRelayExecutor();
        _;
    }

    constructor(address _initialOwner, address _priceFeed)
        Ownable(_initialOwner)
        EIP712("PetitionCore", "1")
    {
        require(_priceFeed != address(0), "Invalid price feed address");
        priceFeed = AggregatorV3Interface(_priceFeed);
        nextReceiptNo = 1;
    }

    function setGovernanceExecutor(address _exec) external onlyOwner {
        if (_exec == address(0)) revert PetitionCore__InvalidAddress();
        governanceExecutor = _exec;
        emit GovernanceExecutorUpdated(_exec);
    }

    function setRelayExecutor(address _executor) external onlyOwner {
        if (_executor == address(0)) revert PetitionCore__InvalidAddress();
        relayExecutor = _executor;
        emit RelayExecutorUpdated(_executor);
    }

    function createCampaign(
        address _beneficiary,
        address _asset,
        uint256 _targetAmount,
        uint256 _durationInDays,
        string memory _arweaveTxId,
        bytes32 _contentHash,
        bytes memory _signature,
        PetitionType _petitionType
    ) external whenNotPaused returns (uint256) {
        return _createCampaignFor(
            _buildCreateParams(
                msg.sender,
                false,
                _beneficiary,
                _asset,
                _targetAmount,
                _durationInDays,
                _arweaveTxId,
                _contentHash,
                _signature,
                _petitionType
            )
        );
    }

    function createDaoCampaign(
        address _beneficiary,
        address _asset,
        uint256 _targetAmount,
        uint256 _durationInDays,
        string memory _arweaveTxId,
        bytes32 _contentHash,
        bytes memory _signature,
        PetitionType _petitionType
    ) external whenNotPaused returns (uint256) {
        if (!_isDaoMember(msg.sender)) revert PetitionCore__OnlyDAOMember();
        return _createCampaignFor(
            _buildCreateParams(
                msg.sender,
                true,
                _beneficiary,
                _asset,
                _targetAmount,
                _durationInDays,
                _arweaveTxId,
                _contentHash,
                _signature,
                _petitionType
            )
        );
    }

    function relayCreateCampaign(
        address user,
        address beneficiary,
        uint256 targetAmount,
        uint256 durationInDays,
        string calldata arweaveTxId,
        bytes32 contentHash,
        bytes calldata signature,
        bool isDaoCampaign,
        uint8 petitionType
    ) external onlyRelayExecutor whenNotPaused nonReentrant returns (uint256) {
        if (user == address(0)) revert PetitionCore__InvalidAddress();
        if (petitionType > uint8(PetitionType.Nonprofit)) {
            revert PetitionCoreTypeLib.PetitionCore__InvalidPetitionType();
        }
        return _createCampaignFor(
            _buildCreateParams(
                user,
                isDaoCampaign,
                beneficiary,
                address(0),
                targetAmount,
                durationInDays,
                arweaveTxId,
                contentHash,
                signature,
                PetitionType(petitionType)
            )
        );
    }

    function _buildCreateParams(
        address creator,
        bool isDao,
        address beneficiary,
        address asset,
        uint256 targetAmount,
        uint256 durationInDays,
        string memory arweaveTxId,
        bytes32 contentHash,
        bytes memory signature,
        PetitionType petitionType
    ) internal pure returns (CreateCampaignParams memory p) {
        p.creator = creator;
        p.isDao = isDao;
        p.beneficiary = beneficiary;
        p.asset = asset;
        p.targetAmount = targetAmount;
        p.durationInDays = durationInDays;
        p.arweaveTxId = arweaveTxId;
        p.contentHash = contentHash;
        p.signature = signature;
        p.petitionType = petitionType;
    }

    function relayFinalizeSign(uint256 campaignId, address user, string calldata message)
        external
        onlyRelayExecutor
        campaignExists(campaignId)
        campaignActive(campaignId)
    {
        if (user == address(0)) revert PetitionCore__InvalidAddress();
        if (address(profileRegistry) == address(0)) revert PetitionCore__ProfileNotSet();
        profileRegistry.signForCampaignAuthorized(campaignId, user);
        _syncSignatureState(campaignId, user, message);
    }

    function relayContribute(address user, uint256 campaignId)
        external
        payable
        onlyRelayExecutor
        campaignExists(campaignId)
        campaignActive(campaignId)
        whenNotPaused
        nonReentrant
    {
        if (user == address(0)) revert PetitionCore__InvalidAddress();
        _contributeETHFor(user, campaignId, msg.value);
    }

    function _createCampaignFor(CreateCampaignParams memory p) internal returns (uint256) {
        if (p.isDao && !_isDaoMember(p.creator)) revert PetitionCore__OnlyDAOMember();
        if (p.targetAmount == 0) revert PetitionCore__InvalidTargetAmount();
        if (p.asset != address(0)) revert PetitionCore__InvalidAsset();

        PetitionCoreTypeLib.validatePetitionType(
            p.petitionType, p.durationInDays, p.creator, address(beneficiaryRegistry)
        );

        uint256 deadline = p.durationInDays == 0 ? 0 : block.timestamp + (p.durationInDays * 1 days);
        if (deadline != 0 && deadline <= block.timestamp) revert PetitionCore__InvalidDeadline();

        PetitionCoreMetaLib.verifyMetadataSignature(
            _domainSeparatorV4(), p.creator, p.arweaveTxId, p.contentHash, p.signature
        );

        uint256 campaignId = nextCampaignId++;

        campaigns[campaignId] = Campaign({
            id: campaignId,
            creator: p.creator,
            beneficiary: p.beneficiary,
            asset: p.asset,
            targetAmount: p.targetAmount,
            fundsRaised: 0,
            signatureCount: 0,
            contributionCount: 0,
            deadline: deadline,
            isDaoCampaign: p.isDao,
            isActive: true,
            fundsWithdrawn: false,
            arweaveTxId: p.arweaveTxId,
            contentHash: p.contentHash,
            petitionType: p.petitionType
        });

        if (deadline != 0 && !_inDeadlineList[campaignId]) {
            _inDeadlineList[campaignId] = true;
            _campaignsWithDeadlines.push(campaignId);
        }

        userCampaigns[p.creator].push(campaignId);
        activeCampaignCount += 1;

        emit CampaignCreatedLite(
            campaignId,
            p.creator,
            p.beneficiary,
            p.asset,
            p.targetAmount,
            deadline,
            p.arweaveTxId,
            p.contentHash,
            p.petitionType,
            p.isDao
        );

        return campaignId;
    }

    function toggleCampaignStatus(uint256 _campaignId) external onlyCampaignCreator(_campaignId) {
        Campaign storage c = campaigns[_campaignId];

        bool wasActive = c.isActive;
        bool wasLogicallyActive = wasActive && (c.deadline == 0 || block.timestamp <= c.deadline);

        c.isActive = !c.isActive;

        if (wasLogicallyActive && !c.isActive) {
            if (activeCampaignCount > 0) activeCampaignCount--;
        } else if (!wasLogicallyActive && c.isActive) {
            activeCampaignCount++;
        }

        emit CampaignStatusChanged(_campaignId, c.isActive);
    }

    /// @notice Links a Lens post to a campaign for off-chain comments (creator, once, while active).
    /// @dev Store keccak256(bytes(lensPostId)) if the Lens post id is a string longer than 32 bytes.
    function setLensPost(uint256 campaignId, bytes32 lensPostId)
        external
        campaignExists(campaignId)
        onlyCampaignCreator(campaignId)
        campaignActive(campaignId)
        whenNotPaused
    {
        if (lensPostId == bytes32(0)) revert PetitionCore__InvalidLensPostId();
        if (lensPostIds[campaignId] != bytes32(0)) revert PetitionCore__LensPostAlreadySet();

        lensPostIds[campaignId] = lensPostId;

        emit LensPostLinked(campaignId, lensPostId, msg.sender);
    }

    /// @notice Sets the platform Lens group id used when creating petition discussion posts.
    /// @dev Only owner. Pass keccak256(bytes(groupId)) if the Lens group id string exceeds 32 bytes.
    function setLensGroupId(bytes32 _lensGroupId) external onlyOwner {
        if (_lensGroupId == bytes32(0)) revert PetitionCore__InvalidLensGroupId();
        lensGroupId = _lensGroupId;
        emit LensGroupIdSet(_lensGroupId, msg.sender);
    }

    /// @notice Returns the platform Lens group id.
    function getLensGroupId() external view returns (bytes32) {
        return lensGroupId;
    }

    function updateCampaignParams(
        uint256 _campaignId,
        uint256 _targetAmount,
        uint256 _newDeadline
    )
        external
        campaignExists(_campaignId)
        onlyCampaignCreator(_campaignId)
        whenNotPaused
    {
        if (_targetAmount == 0) revert PetitionCore__InvalidTargetAmount();

        Campaign storage c = campaigns[_campaignId];
        c.targetAmount = _targetAmount;

        uint256 normalizedDeadline = _newDeadline;

        if (_newDeadline != 0 && _newDeadline <= block.timestamp) {
            normalizedDeadline = 0;
        }

        c.deadline = normalizedDeadline;

        if (normalizedDeadline != 0) {
            if (!_inDeadlineList[_campaignId]) {
                _inDeadlineList[_campaignId] = true;
                _campaignsWithDeadlines.push(_campaignId);
            }
        } else {
            _removeFromDeadlineList(_campaignId);
        }

        emit CampaignParamsUpdated(_campaignId, _targetAmount, normalizedDeadline);
    }

    function updateCampaignMetadata(
        uint256 _campaignId,
        string calldata _arweaveTxId,
        bytes32 _contentHash,
        bytes calldata _signature
    )
        external
        campaignExists(_campaignId)
        onlyCampaignCreator(_campaignId)
        whenNotPaused
    {
        PetitionCoreMetaLib.verifyMetadataSignature(
            _domainSeparatorV4(), msg.sender, _arweaveTxId, _contentHash, _signature
        );

        Campaign storage c = campaigns[_campaignId];
        c.arweaveTxId = _arweaveTxId;
        c.contentHash = _contentHash;

        emit CampaignMetadataUpdated(_campaignId, _arweaveTxId, _contentHash);
    }

    function _autoDeactivateIfExpired(uint256 _campaignId) internal {
        Campaign storage c = campaigns[_campaignId];

        if (c.isActive && c.deadline != 0 && block.timestamp > c.deadline) {
            c.isActive = false;

            if (activeCampaignCount > 0) {
                activeCampaignCount -= 1;
            }

            emit CampaignStatusChanged(_campaignId, false);
            _removeFromDeadlineList(_campaignId);
        }
    }

    function signPetition(uint256 _campaignId, string memory _message)
        external
        payable
        campaignExists(_campaignId)
        campaignActive(_campaignId)
        whenNotPaused
        nonReentrant
    {
        if (address(profileRegistry) == address(0)) revert PetitionCore__ProfileNotSet();
        _chargeSignFee(msg.sender, msg.value);
        profileRegistry.signForCampaignAuthorized(_campaignId, msg.sender);
        _syncSignatureState(_campaignId, msg.sender, _message);
    }

    /// @notice Sign petition and share encrypted signature with campaign beneficiary in one tx.
    function signPetitionAndShare(
        uint256 _campaignId,
        string memory _message,
        string calldata shareArTxId,
        string calldata shareContentHash
    )
        external
        payable
        campaignExists(_campaignId)
        campaignActive(_campaignId)
        whenNotPaused
        nonReentrant
    {
        if (address(profileRegistry) == address(0)) revert PetitionCore__ProfileNotSet();
        _chargeSignFee(msg.sender, msg.value);
        profileRegistry.signForCampaignAuthorizedWithShare(
            _campaignId,
            msg.sender,
            shareArTxId,
            shareContentHash
        );
        _syncSignatureState(_campaignId, msg.sender, _message);
    }

    function _chargeSignFee(address user, uint256 paidWei) internal {
        uint256 usdFeeCents = _isDaoMember(user)
            ? SIGN_FEE_DAO_MEMBER_CENTS
            : SIGN_FEE_NON_DAO_MEMBER_CENTS;

        uint256 requiredWei = calculateSignatureFee(usdFeeCents);

        if (paidWei < requiredWei) revert PetitionCore__InsufficientSignatureFee();

        uint256 refundAmount = paidWei - requiredWei;

        if (refundAmount > 0) {
            (bool refundSuccess,) = payable(user).call{value: refundAmount}("");
            if (!refundSuccess) revert PetitionCore__RefundFailed();
        }
    }

    function _syncSignatureState(uint256 campaignId, address user, string memory message) internal {
        uint256 newCount = profileRegistry.getSignatureCount(campaignId);
        campaigns[campaignId].signatureCount = newCount;

        emit SignatureAddedLight(campaignId, user, message);

        Campaign storage c = campaigns[campaignId];

        if (address(quadraticFundingContract) != address(0)) {
            quadraticFundingContract.reportCampaignData(campaignId, newCount, 0, address(0), c.beneficiary);
        }
    }

    function contributeETH(uint256 _campaignId)
        external
        payable
        campaignExists(_campaignId)
        campaignActive(_campaignId)
        whenNotPaused
        nonReentrant
    {
        _contributeETHFor(msg.sender, _campaignId, msg.value);
    }

    function _contributeETHFor(address user, uint256 campaignId, uint256 value) internal {
        if (value == 0) revert PetitionCore__ZeroContribution();

        Campaign storage c = campaigns[campaignId];

        if (c.asset != address(0)) revert PetitionCore__InvalidAsset();

        ContribCtx memory ctx;
        ctx.campaignId = campaignId;
        ctx.sender = user;
        ctx.value = value;

        ctx.workingWei = _prepareAutosignAndFee(c, ctx);

        _applySplitAndForward(campaignId, c.isDaoCampaign, ctx.workingWei);

        ctx.contributionId = _recordContributionSlim(campaignId, ctx.sender, ctx.workingWei);

        if (address(reputationEngine) != address(0)) {
            reputationEngine.recordDonation(user, ctx.workingWei);
        }

        if (address(badgeSystem) != address(0)) {
            badgeSystem.recordDonation(user, value);
        }

        if (address(endorsementRegistry) != address(0)) {
            endorsementRegistry.recordDonationEndorsement(campaignId, user, ctx.workingWei);
        }

        _refreshAndReport(campaignId, ctx.workingWei, ctx.sender, c.beneficiary);
        _writeReceiptAndEmit(ctx, c.beneficiary);
    }

    function _prepareAutosignAndFee(Campaign storage, ContribCtx memory ctx) internal returns (uint256) {
        if (address(profileRegistry) != address(0) && !_hasSignedView(ctx.campaignId, ctx.sender)) {
            uint256 w = _deductAutosignFeeIfNeeded(true, ctx.sender, ctx.value);
            profileRegistry.signForCampaignAuthorized(ctx.campaignId, ctx.sender);
            emit SignatureAddedLight(ctx.campaignId, ctx.sender, "");
            return w;
        }

        return ctx.value;
    }

    function _hasSignedView(uint256 campaignId, address user) internal view returns (bool) {
        return profileRegistry.hasSigned(campaignId, user);
    }

    function _deductAutosignFeeIfNeeded(bool doSign, address user, uint256 value) internal view returns (uint256) {
        uint256 workingWei = value;

        if (doSign) {
            uint256 usdFeeCents = _isDaoMember(user)
                ? SIGN_FEE_DAO_MEMBER_CENTS
                : SIGN_FEE_NON_DAO_MEMBER_CENTS;

            uint256 feeWei = calculateSignatureFee(usdFeeCents);

            if (workingWei <= feeWei) revert PetitionCore__ZeroContribution();

            unchecked {
                workingWei -= feeWei;
            }
        }

        return workingWei;
    }

    function _applySplitAndForward(uint256 campaignId, bool isDao, uint256 amount) internal {
        PetitionCoreSplitLib.SplitAmounts memory s = PetitionCoreSplitLib.computeSplit(amount, isDao);

        Campaign storage campaign = campaigns[campaignId];
        campaign.fundsRaised += s.beneficiary;

        if (s.creatorReward > 0) {
            daoCreatorRewardBalance[campaign.creator] += s.creatorReward;
            totalDaoCreatorRewardsPending += s.creatorReward;

            emit DaoCampaignCreatorRewardAccrued(campaignId, campaign.creator, s.creatorReward);
        }

        IQuadraticFunding qf = quadraticFundingContract;

        if (address(qf) != address(0)) {
            uint256 feesToForward = s.qf + s.treasury + s.dev;

            if (feesToForward > 0) {
                qf.receiveFees{value: feesToForward}(s.qf, s.treasury, s.dev);
                emit FeesDistributed(campaignId, s.qf, s.treasury, s.dev);
            }
        }
    }

    function _recordContributionSlim(
        uint256 campaignId,
        address contributorAddr,
        uint256 amountWei
    ) internal returns (uint256 contributionId) {
        contributionId = nextContributionId++;

        Contribution storage crec = contributions[contributionId];
        crec.contributor = contributorAddr;
        crec.amount = amountWei;
        crec.timestamp = block.timestamp;
        crec.campaignId = campaignId;

        campaignContributions[campaignId].push(contributionId);
        userContributions[contributorAddr].push(contributionId);

        if (!hasContributed[campaignId][contributorAddr]) {
            hasContributed[campaignId][contributorAddr] = true;
            campaigns[campaignId].contributionCount += 1;
        }

        contributionAmounts[campaignId][contributorAddr] += amountWei;

        emit ContributionMade(campaignId, contributionId, contributorAddr, amountWei);
    }

    function _refreshAndReport(
        uint256 campaignId,
        uint256 workingWei,
        address contributor,
        address beneficiary
    ) internal {
        uint256 sigCount = profileRegistry.getSignatureCount(campaignId);
        campaigns[campaignId].signatureCount = sigCount;

        IQuadraticFunding qf = quadraticFundingContract;

        if (address(qf) != address(0)) {
            qf.reportCampaignData(campaignId, sigCount, workingWei, contributor, beneficiary);
        }
    }

    function _writeReceiptAndEmit(ContribCtx memory ctx, address beneficiary) internal {
        (int256 price, uint8 dec) = PetitionCorePriceLib.latestEthUsdPrice(priceFeed);

        uint256 usdAmountCents = PetitionCorePriceLib.weiToUsdCents(ctx.workingWei, price, dec);

        uint256 receiptNo = nextReceiptNo++;

        ReceiptMeta storage r = _receipts[receiptNo];

        r.donor = ctx.sender;
        r.campaignId = ctx.campaignId;
        r.beneficiary = beneficiary;
        r.contributionWei = ctx.workingWei;
        r.usdAmountCents = usdAmountCents;
        r.ethUsdPrice = price;
        r.priceDecimals = dec;
        r.timestamp = block.timestamp;
        r.chainId = block.chainid;
        r.contributionId = ctx.contributionId;

        _userReceiptNos[ctx.sender].push(receiptNo);

        emit ContributionReceipt(
            receiptNo,
            ctx.sender,
            ctx.campaignId,
            beneficiary,
            ctx.workingWei,
            usdAmountCents,
            price,
            dec,
            block.chainid,
            block.timestamp
        );
    }

    function getUserReceiptNos(uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        uint256[] storage all = _userReceiptNos[msg.sender];

        if (offset >= all.length) return new uint256[](0);

        uint256 end = offset + limit;

        if (end > all.length) end = all.length;

        uint256 count = end - offset;
        uint256[] memory page = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            page[i] = all[offset + i];
        }

        return page;
    }

    function getReceipt(uint256 receiptNo)
        external
        view
        returns (
            address donor,
            uint256 campaignId,
            address beneficiary,
            uint256 contributionWei,
            uint256 usdAmountCents,
            int256 ethUsdPrice,
            uint8 priceDecimals,
            uint256 chainId,
            uint256 timestamp,
            uint256 contributionId,
            string memory arTxId,
            string memory contentHash
        )
    {
        ReceiptMeta storage r = _receipts[receiptNo];

        if (r.donor == address(0)) revert PetitionCore__ReceiptNotFound();
        if (msg.sender != r.donor) revert PetitionCore__NotReceiptOwner();

        return (
            r.donor,
            r.campaignId,
            r.beneficiary,
            r.contributionWei,
            r.usdAmountCents,
            r.ethUsdPrice,
            r.priceDecimals,
            r.chainId,
            r.timestamp,
            r.contributionId,
            r.arTxId,
            r.contentHash
        );
    }

    function registerReceiptDocument(uint256 receiptNo, string calldata arTxId, string calldata contentHash)
        external
        whenNotPaused
    {
        ReceiptMeta storage r = _receipts[receiptNo];

        if (r.donor == address(0)) revert PetitionCore__ReceiptNotFound();
        if (msg.sender != r.donor) revert PetitionCore__NotReceiptOwner();

        r.arTxId = arTxId;
        r.contentHash = contentHash;

        emit ReceiptDocumentSaved(receiptNo, msg.sender, arTxId, contentHash);
    }

    /// @notice Withdraw accrued funds, attaching an Arweave pointer to the off-chain
    ///         withdrawal/history JSON so each on-chain record links to its full report.
    /// @param _campaignId Campaign to withdraw from.
    /// @param _arweaveTxId Arweave transaction id of the withdrawal history JSON (required).
    /// @param _contentHash Hash of the Arweave JSON for integrity (required).
    function withdrawFunds(
        uint256 _campaignId,
        string calldata _arweaveTxId,
        bytes32 _contentHash
    )
        external
        campaignExists(_campaignId)
        whenNotPaused
        nonReentrant
    {
        Campaign storage campaign = campaigns[_campaignId];

        if (msg.sender != campaign.beneficiary) revert PetitionCore__OnlyBeneficiary();
        if (campaign.fundsWithdrawn) revert PetitionCore__FundsAlreadyWithdrawn();

        if (bytes(_arweaveTxId).length == 0 || _contentHash == bytes32(0)) {
            revert PetitionCore__InvalidArweavePointer();
        }

        uint256 available = campaign.fundsRaised - withdrawnAmount[_campaignId];
        if (available == 0) revert PetitionCore__NoFundsToWithdraw();

        bool isOpenEnded = campaign.deadline == 0;

        // Open-ended campaigns that are still running allow streaming withdrawals:
        // the beneficiary takes whatever has accrued and the campaign stays active.
        if (isOpenEnded && campaign.isActive) {
            _settleWithdrawal(_campaignId, campaign, available, false, _arweaveTxId, _contentHash);
            return;
        }

        // Otherwise this is a finalizing withdrawal: only allowed once the campaign
        // is no longer logically active (deadline passed or manually ended).
        if (campaign.isActive && block.timestamp <= campaign.deadline) {
            revert PetitionCore__CampaignStillActive();
        }

        campaign.fundsWithdrawn = true;

        if (campaign.isActive) {
            campaign.isActive = false;

            if (activeCampaignCount > 0) {
                activeCampaignCount -= 1;
            }
        }

        _settleWithdrawal(_campaignId, campaign, available, true, _arweaveTxId, _contentHash);
    }

    /// @dev Records, accounts, and transfers a withdrawal. `finalized` marks campaign-ending withdrawals.
    function _settleWithdrawal(
        uint256 _campaignId,
        Campaign storage campaign,
        uint256 amount,
        bool finalized,
        string memory arweaveTxId,
        bytes32 contentHash
    ) internal {
        withdrawnAmount[_campaignId] += amount;

        _campaignWithdrawals[_campaignId].push(
            WithdrawalRecord({
                amount: amount,
                timestamp: uint64(block.timestamp),
                beneficiary: campaign.beneficiary,
                finalized: finalized,
                arweaveTxId: arweaveTxId,
                contentHash: contentHash
            })
        );

        uint256 recordIndex = _campaignWithdrawals[_campaignId].length - 1;

        (bool success,) = payable(campaign.beneficiary).call{value: amount}("");
        if (!success) revert PetitionCore__WithdrawalFailed();

        emit FundsWithdrawn(_campaignId, campaign.beneficiary, amount);
        emit CampaignWithdrawalRecorded(
            _campaignId,
            campaign.beneficiary,
            amount,
            finalized,
            recordIndex,
            withdrawnAmount[_campaignId],
            arweaveTxId,
            contentHash
        );
    }

    /// @notice Beneficiary-withdrawable balance accrued but not yet withdrawn.
    function getWithdrawableAmount(uint256 _campaignId)
        external
        view
        campaignExists(_campaignId)
        returns (uint256)
    {
        return campaigns[_campaignId].fundsRaised - withdrawnAmount[_campaignId];
    }

    /// @notice Number of withdrawals made for a campaign.
    function getCampaignWithdrawalCount(uint256 _campaignId)
        external
        view
        campaignExists(_campaignId)
        returns (uint256)
    {
        return _campaignWithdrawals[_campaignId].length;
    }

    /// @notice Full withdrawal history for a campaign.
    function getCampaignWithdrawals(uint256 _campaignId)
        external
        view
        campaignExists(_campaignId)
        returns (WithdrawalRecord[] memory)
    {
        return _campaignWithdrawals[_campaignId];
    }


    function claimDaoCreatorRewards()
        external
        whenNotPaused
        nonReentrant
    {
        uint256 amount = daoCreatorRewardBalance[msg.sender];

        if (amount == 0) revert PetitionCore__NoCreatorRewards();

        daoCreatorRewardBalance[msg.sender] = 0;

        if (totalDaoCreatorRewardsPending >= amount) {
            totalDaoCreatorRewardsPending -= amount;
        } else {
            totalDaoCreatorRewardsPending = 0;
        }

        (bool success, ) = payable(msg.sender).call{value: amount}("");

        if (!success) revert PetitionCore__CreatorRewardTransferFailed();

        emit DaoCampaignCreatorRewardClaimed(msg.sender, amount);
    }

    function getCampaignInfo(uint256 _campaignId)
        external
        view
        campaignExists(_campaignId)
        returns (Campaign memory)
    {
        return campaigns[_campaignId];
    }

    /// @notice Used by Profile to gate beneficiary-only signature share reads.
    function getCampaignBeneficiary(uint256 _campaignId)
        external
        view
        campaignExists(_campaignId)
        returns (address beneficiary)
    {
        return campaigns[_campaignId].beneficiary;
    }

    function getCampaignStats(uint256 _campaignId)
        external
        view
        campaignExists(_campaignId)
        returns (
            uint256 signatureCount,
            uint256 contributionCount,
            uint256 totalRaised,
            bool isActive,
            uint256 timeRemaining
        )
    {
        return PetitionCoreViewsLib.getCampaignStats(IPetitionCoreCampaignReader(address(this)), _campaignId);
    }

    function getUserContribution(uint256 _campaignId, address _user)
        external
        view
        campaignExists(_campaignId)
        returns (uint256)
    {
        return contributionAmounts[_campaignId][_user];
    }

    function hasUserSigned(uint256 _campaignId, address _user)
        external
        view
        campaignExists(_campaignId)
        returns (bool)
    {
        if (address(profileRegistry) == address(0)) return false;

        return profileRegistry.hasSigned(_campaignId, _user);
    }

    function getSignatureCount(uint256 _campaignId)
        external
        view
        campaignExists(_campaignId)
        returns (uint256)
    {
        if (address(profileRegistry) == address(0)) return campaigns[_campaignId].signatureCount;

        return profileRegistry.getSignatureCount(_campaignId);
    }

    function getCampaignPointer(uint256 _campaignId)
        external
        view
        campaignExists(_campaignId)
        returns (string memory arTxId, bytes32 contentHash)
    {
        Campaign storage c = campaigns[_campaignId];

        return (c.arweaveTxId, c.contentHash);
    }

    // ---------------- Governance-controlled admin ----------------

    function pause() external onlyGovernance {
        _pause();
    }

    function unpause() external onlyGovernance {
        _unpause();
    }

    function setQuadraticFundingContract(address _qfContract) external onlyGovernance {
        if (_qfContract == address(0)) revert PetitionCore__InvalidQFContract();

        quadraticFundingContract = IQuadraticFunding(_qfContract);

        emit QFContractUpdated(_qfContract);
    }

    function setProfileRegistry(address _profile) external onlyGovernance {
        if (_profile == address(0)) revert PetitionCore__InvalidAddress();

        profileRegistry = IProfileRegistry(_profile);

        emit ProfileRegistryUpdated(_profile);
    }

    function emergencyWithdraw() external onlyGovernance {
        // Deduct pending creator rewards so they are not swept — 
        // those belong to campaign creators, not governance.
        uint256 protected = totalDaoCreatorRewardsPending;
        uint256 balance = address(this).balance;
        uint256 amount = balance > protected ? balance - protected : 0;

        if (amount == 0) revert PetitionCore__NoFundsAvailableForWithdrawal(); // reuse or add a NoFundsError

        (bool success, ) = payable(governanceExecutor).call{value: amount}("");

        require(success, "Emergency withdrawal failed");

        emit EmergencyWithdrawal(governanceExecutor, amount);
    }

    function setReputationEngine(address _reputationEngine) external onlyGovernance {
        reputationEngine = ReputationEngine(_reputationEngine);

        emit ReputationEngineUpdated(_reputationEngine);
    }

    function setBadgeSystem(address _badgeSystem) external onlyGovernance {
        badgeSystem = IBadgeSystem(_badgeSystem);

        emit BadgeSystemUpdated(_badgeSystem);
    }

    function setDaoRegistry(address _daoRegistry) external onlyGovernance {
        if (_daoRegistry == address(0)) revert PetitionCore__InvalidAddress();

        daoRegistry = IDAORegistryLike(_daoRegistry);

        emit DaoRegistryUpdated(_daoRegistry);
    }

    function setBeneficiaryRegistry(address _beneficiaryRegistry) external onlyGovernance {
        if (_beneficiaryRegistry == address(0)) revert PetitionCore__InvalidAddress();

        beneficiaryRegistry = IBeneficiaryRegistry(_beneficiaryRegistry);

        emit BeneficiaryRegistryUpdated(_beneficiaryRegistry);
    }

    function setVotingPower(address _votingPower) external onlyGovernance {
        if (_votingPower == address(0)) revert PetitionCore__InvalidAddress();

        votingPower = IVotingPower(_votingPower);

        emit VotingPowerUpdated(_votingPower);
    }

    function setEndorsementRegistry(address _endorsementRegistry) external onlyGovernance {
        endorsementRegistry = EndorsementRegistry(_endorsementRegistry);

        emit EndorsementRegistryUpdated(_endorsementRegistry);
    }

    function calculateSignatureFee(uint256 usdFeeCents) public view returns (uint256) {
        return PetitionCorePriceLib.calculateSignatureFee(priceFeed, usdFeeCents);
    }

    function _isDaoMember(address user) internal view returns (bool) {
        if (address(daoRegistry) == address(0)) return false;

        return daoRegistry.isDAOMember(user);
    }

    function getDeadlineListLength() external view returns (uint256) {
        return _campaignsWithDeadlines.length;
    }

    function getDeadlineCampaignId(uint256 index) external view returns (uint256) {
        return _campaignsWithDeadlines[index];
    }

    function getCampaignExpiryState(uint256 campaignId)
        external
        view
        returns (bool isActive, uint256 deadline)
    {
        Campaign storage c = campaigns[campaignId];
        return (c.isActive, c.deadline);
    }

    function endIfExpired(uint256 _campaignId)
        public
        campaignExists(_campaignId)
        whenNotPaused
        nonReentrant
    {
        Campaign storage c = campaigns[_campaignId];

        if (!c.isActive) return;
        if (c.deadline == 0) return;
        if (block.timestamp <= c.deadline) return;

        c.isActive = false;

        if (activeCampaignCount > 0) {
            activeCampaignCount -= 1;
        }

        emit CampaignStatusChanged(_campaignId, false);

        uint256 amount = c.fundsRaised - withdrawnAmount[_campaignId];

        if (!c.fundsWithdrawn && amount > 0) {
            c.fundsWithdrawn = true;
            // Automated payout: no off-chain JSON is produced, so the pointer is empty.
            _settleWithdrawal(_campaignId, c, amount, true, "", bytes32(0));
        }
    }

    function _removeFromDeadlineList(uint256 id) internal {
        if (!_inDeadlineList[id]) return;

        uint256 len = _campaignsWithDeadlines.length;

        for (uint256 i = 0; i < len; i++) {
            if (_campaignsWithDeadlines[i] == id) {
                _campaignsWithDeadlines[i] = _campaignsWithDeadlines[len - 1];
                _campaignsWithDeadlines.pop();
                _inDeadlineList[id] = false;

                break;
            }
        }
    }

    function getTotalCampaigns() external view returns (uint256) {
        return nextCampaignId;
    }

    function getTotalActiveCampaigns() external view returns (uint256) {
        return activeCampaignCount;
    }

    function getAllCampaigns(bool onlyActive, uint256 page)
        external
        view
        returns (Campaign[] memory items, uint256 total)
    {
        return PetitionCoreViewsLib.getAllCampaigns(IPetitionCoreCampaignReader(address(this)), onlyActive, page, PAGE_SIZE);
    }

    function markPetitionSuccessful(uint256 _campaignId)
        external
        campaignExists(_campaignId)
        onlyCampaignCreator(_campaignId)
    {
        PetitionCoreReputationLib.markSuccessfulPetition(
            reputationEngine, badgeSystem, endorsementRegistry, campaigns[_campaignId].creator
        );
    }

    function recordHelpfulComment(address user) external onlyGovernance {
        PetitionCoreReputationLib.recordHelpfulComment(reputationEngine, badgeSystem, user);
    }

    function recordInappropriateContent(address user) external onlyGovernance {
        PetitionCoreReputationLib.recordInappropriateContent(reputationEngine, user);
    }

    function recordSpamPetition(address user) external onlyGovernance {
        PetitionCoreReputationLib.recordSpamPetition(reputationEngine, user);
    }

    function recordSuccessfulReport(address reporter) external onlyGovernance {
        PetitionCoreReputationLib.recordSuccessfulReport(badgeSystem, reporter);
    }

    function recordFirstInteraction(address user) external onlyGovernance {
        PetitionCoreReputationLib.recordFirstInteraction(badgeSystem, user);
    }

    function triggerVotingPowerUpdate(address user) external {
        if (
            msg.sender != address(endorsementRegistry) && msg.sender != address(reputationEngine)
                && msg.sender != address(badgeSystem) && msg.sender != governanceExecutor
        ) {
            revert PetitionCore__UnauthorizedCaller();
        }

        if (address(votingPower) != address(0)) {
            votingPower.updateVotingPower(user);
        }
    }

}