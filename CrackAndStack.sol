// SPDX-License-Identifier: MIT

// Message from the author:
// I'm not super proud of this code :')
// I wanted to refactor but...
// I only have 4 hours left until the submission deadline and I still have to record and edit the video 😂😂

pragma solidity ^0.8.0;
import "hardhat/console.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/FunctionsClient.sol";
import "@chainlink/contracts/src/v0.8/functions/dev/v1_0_0/libraries/FunctionsRequest.sol";

interface IHashingContract {
    function checkHash(
        string memory _position,
        uint32 _amountKeys,
        string memory _magicHash,
        bytes32 _comparisonHash
    ) external view returns (bool);
}

contract CrackAndStack is FunctionsClient, VRFConsumerBaseV2, ConfirmedOwner {
    IHashingContract private hasher;

    using FunctionsRequest for FunctionsRequest.Request;

    bytes32 public s_lastRequestId;
    bytes public s_lastResponse;
    bytes public s_lastError;

    error UnexpectedRequestID(bytes32 requestId);

    event Response(bytes32 indexed requestId, bytes response, bytes err);

    uint[] public PROBABILITIES = [3700, 2900, 1250, 1200, 600, 300, 40, 10];
    // Corresponding amounts in wei
    uint[] public AMOUNTS = [
        0.0000166 ether,
        0.000033 ether,
        0.000083 ether,
        0.000166 ether,
        0.000333 ether,
        0.00166 ether,
        0.00833 ether,
        0.133333 ether
    ];

    struct Category {
        uint256 entryFee;
        uint256 initialReward;
    }

    struct Game {
        uint256 category;
        uint256 reward;
        bool isClosed;
    }

    struct GamePass {
        address owner;
        uint256 category;
        uint32 keys;
        bool used;
        bool exchanged;
        bool fake;
    }

    mapping(uint256 => Category) public categories;
    mapping(uint256 => Game) public games;
    mapping(bytes32 => GamePass) public gamePasses;
    mapping(uint256 => uint256) public currentGameByCategory;
    mapping(bytes32 => bytes32[]) public verificationHashes;

    uint256 private nextGameId;
    uint256 private nextGamePassId;

    // Constructor to set the contract deployer as the owner
    constructor()
        VRFConsumerBaseV2(0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed)
        FunctionsClient(0x6E2dc0F9DB014aE19888F539E59285D2Ea04244C)
        ConfirmedOwner(msg.sender)
    {
        COORDINATOR = VRFCoordinatorV2Interface(
            0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed
        );
    }

    function setHasher(IHashingContract _hasher) external {
        hasher = _hasher;
    }

    // Function to create a new category
    function createCategory(
        uint256 _categoryId,
        uint256 _entryFee,
        uint256 _initialReward
    ) public onlyOwner {
        categories[_categoryId] = Category(_entryFee, _initialReward);
    }

    // Function to create a new game
    function createAndUpdateGame(uint256 _categoryId) internal {
        Game memory newGame = Game(
            _categoryId,
            categories[_categoryId].initialReward,
            false
        );
        games[nextGameId] = newGame;
        if (nextGameId > 0) {
            games[currentGameByCategory[_categoryId]].isClosed = true;
        }
        currentGameByCategory[_categoryId] = nextGameId;
        nextGameId++;
    }

    function createGame(uint256 _categoryId) public onlyOwner {
        createAndUpdateGame(_categoryId);
    }

    function verifyGamePass(
        bytes32 _gamePassId,
        string memory _position,
        uint32 _amountKeys,
        string memory _magicHash
    ) public returns (bool) {
        GamePass storage gamePass = gamePasses[_gamePassId];
        require(
            gamePass.owner == msg.sender,
            "Only the owner can verify the GamePass."
        );
        require(!gamePass.used, "GamePass has already been used.");
        bytes32 _comparisonHash = verificationHashes[_gamePassId][_amountKeys];

        bool hashVerified = hasher.checkHash(
            _position,
            _amountKeys,
            _magicHash,
            _comparisonHash
        );

        gamePass.used = true;

        if (hashVerified) {
            if (_amountKeys == 0) {
                gamePass.exchanged = true;
            } else {
                gamePass.keys = _amountKeys;
            }

            requestRandomWords(_gamePassId);

            return true;
        } else {
            gamePass.fake = true;
            gamePass.exchanged = true;
            return false;
        }
    }

    function getRandoms(bytes32 _gamePassId) public {}

    event RewardIncreased(uint256 indexed gameId, uint256 increasedReward);

    function buyGamePasses(
        uint256 _amount,
        uint256 _categoryId,
        bytes32[][] memory _verificationHashes
    ) public payable {
        require(
            _verificationHashes.length == _amount,
            "The size of verificationHashes must be the same as _amount."
        );
        require(
            _amount == 1 || _amount == 5 || _amount == 50,
            "_amount can only be 1, 5 and 50."
        );
        require(
            categories[_categoryId].entryFee != 0,
            "Category does not exist."
        );
        uint256 totalCost = categories[_categoryId].entryFee * _amount;
        require(msg.value >= totalCost, "Insufficient funds sent.");

        for (uint256 i = 0; i < _amount; i++) {
            nextGamePassId++;
            gamePasses[_verificationHashes[i][0]] = GamePass(
                msg.sender,
                _categoryId,
                0,
                false,
                false,
                false
            );
            verificationHashes[_verificationHashes[i][0]] = _verificationHashes[
                i
            ];
        }

        uint256 increasedReward = (((categories[_categoryId].entryFee *
            _amount) * 4) / 10);
        addRewardToGame(currentGameByCategory[_categoryId], increasedReward);
    }

    function addRewardToGame(uint256 gameId, uint256 rewardAmount) internal {
        games[gameId].reward += rewardAmount;
        emit RewardIncreased(gameId, rewardAmount);
    }

    // Function to get the array of values associated with a specific bytes32 key
    function getVerificationHashesByGamePassId(
        bytes32 gamePassId
    ) public view returns (bytes32[] memory) {
        return verificationHashes[gamePassId];
    }

    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(uint256 requestId, uint256[] randomWords);

    struct RequestStatus {
        bool fulfilled; // whether the request has been successfully fulfilled
        bool exists; // whether a requestId exists
        uint256[] randomWords;
        bytes32 gamePassId;
    }
    mapping(uint256 => RequestStatus)
        public s_requests; /* requestId --> requestStatus */
    VRFCoordinatorV2Interface COORDINATOR;

    // Your subscription ID.
    uint64 s_subscriptionId = 6438;

    // past requests Id.
    uint256[] public requestIds;
    uint256 public lastRequestId;

    // The gas lane to use, which specifies the maximum gas price to bump to.
    // For a list of available gas lanes on each network,
    // see https://docs.chain.link/docs/vrf/v2/subscription/supported-networks/#configurations
    bytes32 keyHash =
        0x4b09e658ed251bcafeebbc69400383d49f344ace09b9576fe248bb02c003fe9f;

    // Depends on the number of requested values that you want sent to the
    // fulfillRandomWords() function. Storing each word costs about 20,000 gas,
    // so 100,000 is a safe default for this example contract. Test and adjust
    // this limit based on the network that you select, the size of the request,
    // and the processing of the callback request in the fulfillRandomWords()
    // function.
    uint32 callbackGasLimit = 500000;

    // The default is 3, but you can set this higher.
    uint16 requestConfirmations = 3;

    // Assumes the subscription is funded sufficiently.
    function requestRandomWords(
        bytes32 _gamePassId
    ) internal returns (uint256 requestId) {
        // Will revert if subscription is not set and funded.
        GamePass storage gamePass = gamePasses[_gamePassId];
        require(!gamePass.exchanged, "GamePass has already been exchanged.");

        requestId = COORDINATOR.requestRandomWords(
            keyHash,
            s_subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            gamePass.keys
        );
        s_requests[requestId] = RequestStatus({
            randomWords: new uint256[](0),
            exists: true,
            fulfilled: false,
            gamePassId: _gamePassId
        });
        requestIds.push(requestId);
        lastRequestId = requestId;
        emit RequestSent(requestId, gamePass.keys);
        return requestId;
    }

    function getRequestStatus(
        uint256 _requestId
    ) external view returns (bool fulfilled, uint256[] memory randomWords) {
        require(s_requests[_requestId].exists, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.fulfilled, request.randomWords);
    }

    event KeyGamePassReward(bytes32 gamePassId, uint256 amount, uint key);

    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        require(s_requests[_requestId].exists, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;
        GamePass storage gamePass = gamePasses[
            s_requests[_requestId].gamePassId
        ];
        gamePass.exchanged = true;

        uint256 reward = games[currentGameByCategory[gamePass.category]].reward;

        for (uint i = 0; i < _randomWords.length; ++i) {
            uint256 lastFourDigits = _randomWords[i] % 10000;
            uint256 rewardedAmount = sendEther(
                gamePass,
                lastFourDigits,
                reward
            );
            emit KeyGamePassReward(
                s_requests[_requestId].gamePassId,
                rewardedAmount,
                i + 1
            );
        }

        emit RequestFulfilled(_requestId, _randomWords);
    }

    function sendEther(
        GamePass memory gamePass,
        uint256 rand,
        uint256 reward
    ) internal returns (uint256) {
        uint i;
        for (i = 0; i < PROBABILITIES.length; i++) {
            if (rand < PROBABILITIES[i]) {
                break;
            }
            rand -= PROBABILITIES[i];
        }
        uint amountToSend = (i == 7) ? reward : AMOUNTS[i];
        if (i == 7) {
            createGame(gamePass.category);
        }
        require(
            address(this).balance >= amountToSend,
            "Contract does not have enough ether"
        );
        payable(gamePass.owner).transfer(amountToSend);

        return amountToSend;
    }

    event Received(address, uint);

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    function withdraw(address _to, uint256 _amount) external onlyOwner {
        (bool success, ) = _to.call{value: _amount}("");
        require(success, "WITHDRAW_FAILED");
    }

    mapping(address => bool) public allowedAddresses;

    function setAllowedAddress(
        address _address,
        bool _status
    ) external onlyOwner {
        allowedAddresses[_address] = _status;
    }

    //Function to be called on Chainlink Functions
    function destroyUsedGamePasses(bytes32[] memory _gamePassIds) internal {
        require(allowedAddresses[msg.sender], "Not an allowed address");
        for (uint i = 0; i < _gamePassIds.length; i++) {
            GamePass storage gamePass = gamePasses[_gamePassIds[i]];
            if (gamePass.used) continue;
            if (gamePass.exchanged) continue;

            gamePass.used = true;
            gamePass.exchanged = true;

            uint256 gameId = currentGameByCategory[gamePass.category];
            uint256 rewardToAdd = (categories[gamePass.category].entryFee *
                35) / 100;

            addRewardToGame(gameId, rewardToAdd);
        }
    }

    //CHAINLINK FUNCTIONS
    function sendRequest(
        string memory source,
        bytes memory encryptedSecretsUrls,
        uint8 donHostedSecretsSlotID,
        uint64 donHostedSecretsVersion,
        string[] memory args,
        bytes[] memory bytesArgs,
        uint64 subscriptionId,
        uint32 gasLimit,
        bytes32 donID
    ) external onlyOwner returns (bytes32 requestId) {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(source);
        if (encryptedSecretsUrls.length > 0)
            req.addSecretsReference(encryptedSecretsUrls);
        else if (donHostedSecretsVersion > 0) {
            req.addDONHostedSecrets(
                donHostedSecretsSlotID,
                donHostedSecretsVersion
            );
        }
        if (args.length > 0) req.setArgs(args);
        if (bytesArgs.length > 0) req.setBytesArgs(bytesArgs);
        s_lastRequestId = _sendRequest(
            req.encodeCBOR(),
            subscriptionId,
            gasLimit,
            donID
        );
        return s_lastRequestId;
    }

    function sendRequestCBOR(
        bytes memory request,
        uint64 subscriptionId,
        uint32 gasLimit,
        bytes32 donID
    ) external onlyOwner returns (bytes32 requestId) {
        s_lastRequestId = _sendRequest(
            request,
            subscriptionId,
            gasLimit,
            donID
        );
        return s_lastRequestId;
    }

    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        if (s_lastRequestId != requestId) {
            revert UnexpectedRequestID(requestId);
        }
        s_lastResponse = response;
        s_lastError = err;
        emit Response(requestId, s_lastResponse, s_lastError);

        // Convert bytes response to bytes32[] for destroyUsedGamePasses
        bytes32[] memory gamePassIds = abi.decode(response, (bytes32[]));
        destroyUsedGamePasses(gamePassIds);
    }
}
