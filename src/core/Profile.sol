// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IBadgeSystem.sol";
import "../governance/EndorsementRegistry.sol";
import "../interfaces/governance/IVotingPower.sol";
import "../interfaces/reputation/ICampaignContributionRegistry.sol";

interface IReputationEngine {
    function updateReputation(address user, string memory actionType) external;
    function recordDonation(address user, uint256 amount) external;
    function hasBadge(address user, string memory badge) external view returns (bool);
}

interface IPetitionCoreBeneficiaryReader {
    function getCampaignBeneficiary(uint256 campaignId) external view returns (address beneficiary);
}

contract Profile is ReentrancyGuard, Pausable, Ownable {

    // =========================
    // 🔥 GOVERNANCE
    // =========================
    address public governanceExecutor;

    modifier onlyGovernance() {
        if (msg.sender != governanceExecutor) revert Profile__UnauthorizedModule();
        _;
    }

    function setGovernanceExecutor(address _exec) external onlyOwner {
        governanceExecutor = _exec;
    }

    struct ArweavePtr {
        string arTxId;
        string contentHash;
    }

    struct ProfileData {
        ArweavePtr profileDoc;
        ArweavePtr avatar;
        ArweavePtr firstName;
        ArweavePtr lastName;
        ArweavePtr bio;
        ArweavePtr ens;

        ArweavePtr twitter;
        ArweavePtr github;
        ArweavePtr etherscan;
        ArweavePtr telegram;

        uint256 lastUpdated;
    }

    struct SignatureVersion {
        string arTxId;
        string contentHash;
        uint64 createdAt;
        bool isActive;
    }

    /// @notice Per-campaign signature share for beneficiary PDF export (one row per campaignId + signer).
    struct CampaignSignatureShare {
        string arTxId;
        string contentHash;
        uint256 sigVersionIndex;
        uint64 sharedAt;
        bool isShared;
    }

    mapping(address => ProfileData) private profiles;
    mapping(address => SignatureVersion[]) private userSignatureVersions;
    mapping(address => uint256) private activeSigIndex;

    mapping(uint256 => mapping(address => bool)) private _hasSignedCampaign;
    mapping(uint256 => uint256) private _campaignSignatureCount;
    mapping(uint256 => mapping(address => CampaignSignatureShare)) private _campaignSignatureShares;

    mapping(address => bool) public isAuthorizedModule;
    IPetitionCoreBeneficiaryReader public petitionCore;

    mapping(address => mapping(string => bool)) public socialVerifications;
    mapping(address => uint256) public socialVerificationCount;

    EndorsementRegistry public endorsementRegistry;
    ICampaignContributionRegistry public campaignContributionRegistry;
    IReputationEngine public reputationEngine;
    IBadgeSystem public badgeSystem;
    IVotingPower public votingPower;

    event ProfileUpdated(address indexed user, uint256 timestamp);
    event ProfileModuleAuthorized(address indexed module, bool authorized);
    event SignatureVersionSaved(address indexed user, uint256 index, bool activated);
    event ActiveSignatureVersionSet(address indexed user, uint256 index);
    event CampaignSigned(uint256 indexed campaignId, address indexed signer, uint256 activeSigIndex);
    event SignatureShared(
        uint256 indexed campaignId,
        address indexed signer,
        string arTxId,
        string contentHash,
        uint256 sigVersionIndex
    );
    event PetitionCoreSet(address indexed petitionCore);
    event SocialVerified(address indexed user, string platform);

    event ReputationEngineSet(address indexed rep);
    event BadgeSystemSet(address indexed badge);
    event EndorsementRegistrySet(address indexed endorsementRegistry);
    event CampaignContributionRegistrySet(address indexed registry);
    event VotingPowerSet(address indexed votingPower);
    event GovernanceExecutorSet(address indexed governanceExecutor);

    error Profile__NoActiveSignature();
    error Profile__AlreadySigned();
    error Profile__UnauthorizedModule();
    error Profile__InvalidIndex();
    error Profile__NotSigned();
    error Profile__AlreadyShared();
    error Profile__NotCampaignBeneficiary();
    error Profile__PetitionCoreNotSet();
    error Profile__InvalidSharePointer();

    constructor(address initialOwner) Ownable(initialOwner) {}

    // =========================
    // 🔥 GOVERNANCE CONTROL
    // =========================

    function setReputationEngine(address _reputationEngine) external onlyGovernance {
        reputationEngine = IReputationEngine(_reputationEngine);
        emit ReputationEngineSet(_reputationEngine);
    }

    function setBadgeSystem(address _badgeSystem) external onlyGovernance {
        badgeSystem = IBadgeSystem(_badgeSystem);
        emit BadgeSystemSet(_badgeSystem);
    }

    function setEndorsementRegistry(address _endorsementRegistry) external onlyGovernance {
        endorsementRegistry = EndorsementRegistry(_endorsementRegistry);
        emit EndorsementRegistrySet(_endorsementRegistry);
    }

    function setCampaignContributionRegistry(address registry) external onlyGovernance {
        campaignContributionRegistry = ICampaignContributionRegistry(registry);
        emit CampaignContributionRegistrySet(registry);
    }

    function setVotingPower(address _votingPower) external onlyGovernance {
        votingPower = IVotingPower(_votingPower);
        emit VotingPowerSet(_votingPower);
    }

    function setPetitionCore(address _petitionCore) external onlyGovernance {
        petitionCore = IPetitionCoreBeneficiaryReader(_petitionCore);
        emit PetitionCoreSet(_petitionCore);
    }

    function authorizeModule(address module, bool authorized) external onlyGovernance {
        isAuthorizedModule[module] = authorized;
        emit ProfileModuleAuthorized(module, authorized);
    }

    function pause() external onlyGovernance { _pause(); }
    function unpause() external onlyGovernance { _unpause(); }

    // =========================
    // 🔥 EVERYTHING BELOW UNCHANGED
    // =========================

    function verifySocial(address user, string memory platform) external {
        if (!isAuthorizedModule[msg.sender]) revert Profile__UnauthorizedModule();
        require(!socialVerifications[user][platform], "Already verified");

        socialVerifications[user][platform] = true;
        socialVerificationCount[user]++;

        if (address(reputationEngine) != address(0)) {
            string memory actionType = string(abi.encodePacked("verify_", platform));
            reputationEngine.updateReputation(user, actionType);
        }

        if (address(badgeSystem) != address(0)) {
            badgeSystem.recordAction(user, "social_verifications", 1);
            badgeSystem.recordAction(user, string(abi.encodePacked("verify_", platform)), 1);
        }

        if (address(endorsementRegistry) != address(0)) {
            endorsementRegistry.recordSocialVerification(user, platform);
        }

        if (address(votingPower) != address(0)) {
            votingPower.updateVotingPower(user);
        }

        emit SocialVerified(user, platform);
    }

    function isSocialVerified(address user, string memory platform) external view returns (bool) {
        return socialVerifications[user][platform];
    }

    function getVerifiedSocials(address user) external view returns (string[] memory) {
        // temp buffer
        string[] memory platforms = new string[](4);

        uint256 count = 0;

        if (socialVerifications[user]["twitter"]) platforms[count++] = "twitter";
        if (socialVerifications[user]["github"]) platforms[count++] = "github";
        if (socialVerifications[user]["discord"]) platforms[count++] = "discord";
        if (socialVerifications[user]["telegram"]) platforms[count++] = "telegram";

        // shrink to count
        string[] memory result = new string[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = platforms[i];
        }
        return result;
    }

    // =========================================================
    // Profile API
    // =========================================================

    function updateProfile(
        // Canonical profile JSON
        string calldata profileDocArTxId,
        string calldata profileDocHash,
        // Avatar
        string calldata avatarArTxId,
        string calldata avatarHash,
        // First name
        string calldata firstNameArTxId,
        string calldata firstNameHash,
        // Last name
        string calldata lastNameArTxId,
        string calldata lastNameHash,
        // Bio
        string calldata bioArTxId,
        string calldata bioHash,
        // Socials
        string calldata twitterArTxId,
        string calldata twitterHash,
        string calldata githubArTxId,
        string calldata githubHash,
        string calldata etherscanArTxId,
        string calldata etherscanHash,
        string calldata telegramArTxId,
        string calldata telegramHash,
        // ENS
        string calldata ensArTxId,
        string calldata ensHash
    ) external whenNotPaused nonReentrant {
        ProfileData storage p = profiles[msg.sender];

        // Track which socials are newly added
        bool addedTwitter = false;
        bool addedGithub = false;
        bool addedEtherscan = false;
        bool addedTelegram = false;
        bool addedENS = false;

        // Canonical profile doc
        if (bytes(profileDocArTxId).length != 0 || bytes(profileDocHash).length != 0) {
            if (bytes(profileDocArTxId).length != 0) p.profileDoc.arTxId = profileDocArTxId;
            if (bytes(profileDocHash).length != 0) p.profileDoc.contentHash = profileDocHash;
        }

        // Avatar
        if (bytes(avatarArTxId).length != 0 || bytes(avatarHash).length != 0) {
            if (bytes(avatarArTxId).length != 0) p.avatar.arTxId = avatarArTxId;
            if (bytes(avatarHash).length != 0) p.avatar.contentHash = avatarHash;
        }

        // First name
        if (bytes(firstNameArTxId).length != 0 || bytes(firstNameHash).length != 0) {
            if (bytes(firstNameArTxId).length != 0) p.firstName.arTxId = firstNameArTxId;
            if (bytes(firstNameHash).length != 0) p.firstName.contentHash = firstNameHash;
        }

        // Last name
        if (bytes(lastNameArTxId).length != 0 || bytes(lastNameHash).length != 0) {
            if (bytes(lastNameArTxId).length != 0) p.lastName.arTxId = lastNameArTxId;
            if (bytes(lastNameHash).length != 0) p.lastName.contentHash = lastNameHash;
        }

        // Bio
        if (bytes(bioArTxId).length != 0 || bytes(bioHash).length != 0) {
            if (bytes(bioArTxId).length != 0) p.bio.arTxId = bioArTxId;
            if (bytes(bioHash).length != 0) p.bio.contentHash = bioHash;
        }

        // Twitter
        if (bytes(twitterArTxId).length != 0 || bytes(twitterHash).length != 0) {
            if (bytes(twitterArTxId).length != 0) {
                if (bytes(p.twitter.arTxId).length == 0) addedTwitter = true;
                p.twitter.arTxId = twitterArTxId;
            }
            if (bytes(twitterHash).length != 0) p.twitter.contentHash = twitterHash;
        }

        // GitHub
        if (bytes(githubArTxId).length != 0 || bytes(githubHash).length != 0) {
            if (bytes(githubArTxId).length != 0) {
                if (bytes(p.github.arTxId).length == 0) addedGithub = true;
                p.github.arTxId = githubArTxId;
            }
            if (bytes(githubHash).length != 0) p.github.contentHash = githubHash;
        }

        // Etherscan
        if (bytes(etherscanArTxId).length != 0 || bytes(etherscanHash).length != 0) {
            if (bytes(etherscanArTxId).length != 0) {
                if (bytes(p.etherscan.arTxId).length == 0) addedEtherscan = true;
                p.etherscan.arTxId = etherscanArTxId;
            }
            if (bytes(etherscanHash).length != 0) p.etherscan.contentHash = etherscanHash;
        }

        // Telegram
        if (bytes(telegramArTxId).length != 0 || bytes(telegramHash).length != 0) {
            if (bytes(telegramArTxId).length != 0) {
                if (bytes(p.telegram.arTxId).length == 0) addedTelegram = true;
                p.telegram.arTxId = telegramArTxId;
            }
            if (bytes(telegramHash).length != 0) p.telegram.contentHash = telegramHash;
        }

        // ENS
        if (bytes(ensArTxId).length != 0 || bytes(ensHash).length != 0) {
            if (bytes(ensArTxId).length != 0) {
                if (bytes(p.ens.arTxId).length == 0) addedENS = true;
                p.ens.arTxId = ensArTxId;
            }
            if (bytes(ensHash).length != 0) p.ens.contentHash = ensHash;
        }

        p.lastUpdated = block.timestamp;

        // Auto-verify newly added socials (optional)
        if (address(reputationEngine) != address(0)) {
            if (addedTwitter && !socialVerifications[msg.sender]["twitter"]) {
                socialVerifications[msg.sender]["twitter"] = true;
                socialVerificationCount[msg.sender]++;
                reputationEngine.updateReputation(msg.sender, "verify_twitter");
                emit SocialVerified(msg.sender, "twitter");
            }
            if (addedGithub && !socialVerifications[msg.sender]["github"]) {
                socialVerifications[msg.sender]["github"] = true;
                socialVerificationCount[msg.sender]++;
                reputationEngine.updateReputation(msg.sender, "verify_github");
                emit SocialVerified(msg.sender, "github");
            }
            if (addedEtherscan && !socialVerifications[msg.sender]["etherscan"]) {
                socialVerifications[msg.sender]["etherscan"] = true;
                socialVerificationCount[msg.sender]++;
                reputationEngine.updateReputation(msg.sender, "verify_etherscan");
                emit SocialVerified(msg.sender, "etherscan");
            }
            if (addedTelegram && !socialVerifications[msg.sender]["telegram"]) {
                socialVerifications[msg.sender]["telegram"] = true;
                socialVerificationCount[msg.sender]++;
                reputationEngine.updateReputation(msg.sender, "verify_telegram");
                emit SocialVerified(msg.sender, "telegram");
            }
            if (addedENS && !socialVerifications[msg.sender]["ens"]) {
                socialVerifications[msg.sender]["ens"] = true;
                socialVerificationCount[msg.sender]++;
                reputationEngine.updateReputation(msg.sender, "verify_ens");
                emit SocialVerified(msg.sender, "ens");
            }
        }

        // Voting power checkpoint (optional)
        if (address(votingPower) != address(0)) {
            votingPower.updateVotingPower(msg.sender);
        }

        emit ProfileUpdated(msg.sender, p.lastUpdated);
    }

    function getProfile(address user) external view returns (
        // Canonical profile doc
        string memory profileDocArTxId,
        string memory profileDocHash,
        // Avatar
        string memory avatarArTxId,
        string memory avatarHash,
        // First name
        string memory firstNameArTxId,
        string memory firstNameHash,
        // Last name
        string memory lastNameArTxId,
        string memory lastNameHash,
        // Bio
        string memory bioArTxId,
        string memory bioHash,
        // Socials
        string memory twitterArTxId,
        string memory twitterHash,
        string memory githubArTxId,
        string memory githubHash,
        string memory etherscanArTxId,
        string memory etherscanHash,
        string memory telegramArTxId,
        string memory telegramHash,
        // ENS
        string memory ensArTxId,
        string memory ensHash,
        uint256 lastUpdated
    ) {
        ProfileData storage p = profiles[user];
        return (
            p.profileDoc.arTxId, p.profileDoc.contentHash,
            p.avatar.arTxId, p.avatar.contentHash,
            p.firstName.arTxId, p.firstName.contentHash,
            p.lastName.arTxId, p.lastName.contentHash,
            p.bio.arTxId, p.bio.contentHash,
            p.twitter.arTxId, p.twitter.contentHash,
            p.github.arTxId, p.github.contentHash,
            p.etherscan.arTxId, p.etherscan.contentHash,
            p.telegram.arTxId, p.telegram.contentHash,
            p.ens.arTxId, p.ens.contentHash,
            p.lastUpdated
        );
    }

    // =========================================================
    // Signature Versions
    // =========================================================

    function saveSignatureVersion(
        string calldata arTxId,
        string calldata contentHash,
        bool activate
    ) external whenNotPaused nonReentrant {
        SignatureVersion memory v = SignatureVersion({
            arTxId: arTxId,
            contentHash: contentHash,
            createdAt: uint64(block.timestamp),
            isActive: activate
        });

        userSignatureVersions[msg.sender].push(v);
        uint256 idx = userSignatureVersions[msg.sender].length - 1;

        if (activate) {
            _setActiveSigIndex(msg.sender, idx);
        }

        emit SignatureVersionSaved(msg.sender, idx, activate);
    }

    function setActiveSignatureVersion(uint256 index) external whenNotPaused {
        if (index >= userSignatureVersions[msg.sender].length) revert Profile__InvalidIndex();
        _setActiveSigIndex(msg.sender, index);
        emit ActiveSignatureVersionSet(msg.sender, index);
    }

    function _setActiveSigIndex(address user, uint256 index) internal {
        uint256 prev = activeSigIndex[user];
        if (prev < userSignatureVersions[user].length) {
            userSignatureVersions[user][prev].isActive = false;
        }
        activeSigIndex[user] = index;
        userSignatureVersions[user][index].isActive = true;
    }

    function getActiveSignatureVersion(address user) external view returns (
        string memory arTxId,
        string memory contentHash,
        uint64 createdAt,
        bool isActive
    ) {
        uint256 idx = activeSigIndex[user];
        if (idx >= userSignatureVersions[user].length) {
            return ("", "", 0, false);
        }
        SignatureVersion storage v = userSignatureVersions[user][idx];
        return (v.arTxId, v.contentHash, v.createdAt, v.isActive);
    }

    function getSignatureVersionsCount(address user) external view returns (uint256) {
        return userSignatureVersions[user].length;
    }

    // =========================================================
    // Campaign Signing
    // =========================================================

    function hasSigned(uint256 campaignId, address user) external view returns (bool) {
        return _hasSignedCampaign[campaignId][user];
    }

    function getSignatureCount(uint256 campaignId) external view returns (uint256) {
        return _campaignSignatureCount[campaignId];
    }

    function publicSign(uint256 campaignId) external whenNotPaused nonReentrant {
        _sign(campaignId, msg.sender);
    }

    /// @notice Sign a campaign and share encrypted signature pointers with the campaign beneficiary (same tx).
    function publicSignAndShare(
        uint256 campaignId,
        string calldata shareArTxId,
        string calldata shareContentHash
    ) external whenNotPaused nonReentrant {
        uint256 sigIdx = _sign(campaignId, msg.sender);
        _recordSignatureShare(campaignId, msg.sender, shareArTxId, shareContentHash, sigIdx);
    }

    /// @notice After signing, opt in to share signature with the campaign beneficiary (one share per campaign).
    function shareSignatureForCampaign(
        uint256 campaignId,
        string calldata shareArTxId,
        string calldata shareContentHash
    ) external whenNotPaused nonReentrant {
        if (!_hasSignedCampaign[campaignId][msg.sender]) revert Profile__NotSigned();
        uint256 sigIdx = _activeSigIndexOrMax(msg.sender);
        _recordSignatureShare(campaignId, msg.sender, shareArTxId, shareContentHash, sigIdx);
    }

    function signForCampaignAuthorized(uint256 campaignId, address signer)
        external
        whenNotPaused
        nonReentrant
    {
        if (!isAuthorizedModule[msg.sender]) revert Profile__UnauthorizedModule();
        _signAuthorized(campaignId, signer);
    }

    /// @notice Authorized module sign + beneficiary share (e.g. PetitionCore signPetitionAndShare).
    function signForCampaignAuthorizedWithShare(
        uint256 campaignId,
        address signer,
        string calldata shareArTxId,
        string calldata shareContentHash
    ) external whenNotPaused nonReentrant {
        if (!isAuthorizedModule[msg.sender]) revert Profile__UnauthorizedModule();
        uint256 sigIdx = _signAuthorized(campaignId, signer);
        _recordSignatureShare(campaignId, signer, shareArTxId, shareContentHash, sigIdx);
    }

    function hasSharedSignature(uint256 campaignId, address signer) external view returns (bool) {
        return _campaignSignatureShares[campaignId][signer].isShared;
    }

    /// @notice Signer reads their own share record for a campaign.
    function getMySharedSignature(uint256 campaignId)
        external
        view
        returns (
            string memory arTxId,
            string memory contentHash,
            uint256 sigVersionIndex,
            uint64 sharedAt,
            bool isShared
        )
    {
        CampaignSignatureShare storage s = _campaignSignatureShares[campaignId][msg.sender];
        return (s.arTxId, s.contentHash, s.sigVersionIndex, s.sharedAt, s.isShared);
    }

    /// @notice Campaign beneficiary reads a signer's shared signature (DAO: creator cannot call).
    function getSharedSignature(uint256 campaignId, address signer)
        external
        view
        returns (
            string memory arTxId,
            string memory contentHash,
            uint256 sigVersionIndex,
            uint64 sharedAt,
            bool isShared
        )
    {
        _requireCampaignBeneficiary(campaignId);
        CampaignSignatureShare storage s = _campaignSignatureShares[campaignId][signer];
        return (s.arTxId, s.contentHash, s.sigVersionIndex, s.sharedAt, s.isShared);
    }

    function _sign(uint256 campaignId, address signer) internal returns (uint256 idx) {
        idx = activeSigIndex[signer];
        if (idx >= userSignatureVersions[signer].length || !userSignatureVersions[signer][idx].isActive) {
            revert Profile__NoActiveSignature();
        }
        if (_hasSignedCampaign[campaignId][signer]) revert Profile__AlreadySigned();

        _hasSignedCampaign[campaignId][signer] = true;
        _campaignSignatureCount[campaignId] += 1;

        _recordSignContribution(campaignId, signer);

        if (address(reputationEngine) != address(0)) {
            reputationEngine.updateReputation(signer, "petition_signature");
        }

        if (address(votingPower) != address(0)) {
            votingPower.updateVotingPower(signer);
        }

        emit CampaignSigned(campaignId, signer, idx);
    }

    function _signAuthorized(uint256 campaignId, address signer) internal returns (uint256 idx) {
        if (_hasSignedCampaign[campaignId][signer]) revert Profile__AlreadySigned();

        _hasSignedCampaign[campaignId][signer] = true;
        _campaignSignatureCount[campaignId] += 1;

        _recordSignContribution(campaignId, signer);

        if (address(reputationEngine) != address(0)) {
            reputationEngine.updateReputation(signer, "petition_signature");
        }

        if (address(votingPower) != address(0)) {
            votingPower.updateVotingPower(signer);
        }

        idx = _activeSigIndexOrMax(signer);
        emit CampaignSigned(campaignId, signer, idx);
    }

    function _recordSignContribution(uint256 campaignId, address signer) internal {
        if (address(campaignContributionRegistry) == address(0)) return;
        campaignContributionRegistry.recordSignContribution(
            campaignId, signer, _campaignSignatureCount[campaignId]
        );
    }

    function _activeSigIndexOrMax(address signer) internal view returns (uint256 idx) {
        idx = activeSigIndex[signer];
        if (idx >= userSignatureVersions[signer].length || !userSignatureVersions[signer][idx].isActive) {
            idx = type(uint256).max;
        }
    }

    function _recordSignatureShare(
        uint256 campaignId,
        address signer,
        string calldata shareArTxId,
        string calldata shareContentHash,
        uint256 sigVersionIndex
    ) internal {
        if (bytes(shareArTxId).length == 0 || bytes(shareContentHash).length == 0) {
            revert Profile__InvalidSharePointer();
        }

        CampaignSignatureShare storage share = _campaignSignatureShares[campaignId][signer];
        if (share.isShared) revert Profile__AlreadyShared();

        share.arTxId = shareArTxId;
        share.contentHash = shareContentHash;
        share.sigVersionIndex = sigVersionIndex;
        share.sharedAt = uint64(block.timestamp);
        share.isShared = true;

        emit SignatureShared(campaignId, signer, shareArTxId, shareContentHash, sigVersionIndex);
    }

    function _campaignBeneficiary(uint256 campaignId) internal view returns (address beneficiary) {
        if (address(petitionCore) == address(0)) revert Profile__PetitionCoreNotSet();
        beneficiary = petitionCore.getCampaignBeneficiary(campaignId);
        if (beneficiary == address(0)) revert Profile__NotCampaignBeneficiary();
    }

    function _requireCampaignBeneficiary(uint256 campaignId) internal view {
        if (msg.sender != _campaignBeneficiary(campaignId)) revert Profile__NotCampaignBeneficiary();
    }
}