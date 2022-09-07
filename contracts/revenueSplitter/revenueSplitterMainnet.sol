pragma solidity ^0.8.0;

// interface for uniswap
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

// interface for callback on tokens sent
import "./Interfaces/IShareholder.sol";
import "./Interfaces/ITokenController.sol";
import "./Interfaces/IControlled.sol";
import "./Interfaces/IWETH.sol";
import { IPolygonBridgeExit } from "./PolygonInterfaces.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract RevenueSplitterWithController is OwnableUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public baseToken;
    IWETH public WETH; 
    ITokenController public baseTokenController;
    IPolygonBridgeExit internal polygonBridgeRoot;
    ISwapRouter public swapRouter;
    // path for uniswap trade as `bytes path` see ISwapRouter
    mapping(address => bytes) internal _swappingPaths;

    uint256 public totalShares;
    uint256 public totalSharesBaseReceiver;

    Shareholder[] internal baseTokenReceiver;
    Shareholder[] internal rawTokenReceiver;

    struct Shareholder {
        address account;
        uint88 shares;
        bool toBeNotified;
    }

    constructor() initializer {}

    function initialize(
        IERC20 _baseToken,
        IWETH wrappedEth,
        ISwapRouter _swapRouter,
        Shareholder[] memory initialShareholders,
        bool[] memory isRawTokenReceiver,
        address[] memory tokens,
        bytes[] memory tokenPaths
    ) public initializer {
        require(initialShareholders.length == isRawTokenReceiver.length, "lengths invalid");
        require(tokens.length == tokenPaths.length, "lengths invalid");

        __Ownable_init();

        baseToken = _baseToken;
        WETH = wrappedEth;
        baseTokenController = ITokenController(IControlled(address(_baseToken)).controller());

        swapRouter = _swapRouter;

        for(uint256 i = 0; i < initialShareholders.length; i++) {
            if(isRawTokenReceiver[i]) {
                addRawTokenReceiver(initialShareholders[i]);
                continue;
            }
            addBaseTokenReceiver(initialShareholders[i]);
        }

        for(uint256 i = 0; i < tokens.length; i++) {
            setSwappingPath(tokens[i], tokenPaths[i]);
        }
    }

    /// @dev reverts on baseToken as input
    /// @dev reverts if token has no swapping path defined (`_swappingPaths[token]`)
    function swapAndDistributeMany(IERC20[] memory tokens) public onlyOwner {
        uint256 _totalShares = totalShares;
        uint256 rawTokenReceiverCount = rawTokenReceiver.length;
        
        for(uint256 i = 0; i < tokens.length; i++) {
            IERC20 token = tokens[i];
            if(address(token) == address(WETH)) WETH.deposit{ value: address(this).balance }();

            uint256 balance = token.balanceOf(address(this));
            uint256 swapAmount = balance;
            for(uint256 k = 0; k < rawTokenReceiverCount; k++) {
                uint256 transferAmount = balance * rawTokenReceiver[k].shares / _totalShares;
                token.safeTransfer(
                    rawTokenReceiver[k].account, 
                    transferAmount
                );
                if(rawTokenReceiver[k].toBeNotified) {
                    require(
                        IShareholder(rawTokenReceiver[k].account)
                            .notifyShareholder(address(token), transferAmount), 
                            "callback failed"
                    );
                }
                swapAmount -= transferAmount;
            }
            if(swapAmount == 0) continue;
            swapRouter.exactInput(
                buildSwapParams(address(token), swapAmount)
            );
            emit TokensDistributed(address(token), block.timestamp);
        }
        distributeBaseToken();
    }

    /// @dev reverts on baseToken as input
    /// @dev reverts if token has no swapping path defined (`_swappingPaths[token]`)
    function swapAndDistributeSingle(address token) public onlyOwner {
        if(token == address(WETH)) WETH.deposit{ value: address(this).balance }();
        uint256 balance = balanceOfToken(token);
        uint256 swapAmount = balance;
        require(balance != 0, "nothing to distribute");

        uint256 _totalShares = totalShares;
        uint256 rawTokenReceiverCount = rawTokenReceiver.length;

        for(uint256 i = 0; i < rawTokenReceiverCount; i++) {
            Shareholder storage shareholder = rawTokenReceiver[i];
            uint256 transferAmount = balance * shareholder.shares / _totalShares;
            IERC20(token).safeTransfer(shareholder.account, transferAmount);
            swapAmount -= transferAmount;
            if(shareholder.toBeNotified) {
                require(
                    IShareholder(shareholder.account)
                        .notifyShareholder(address(token), transferAmount), 
                    "callback failed"
                );
            }
        }
        // swap
        if(swapAmount == 0) return;
        swapRouter.exactInput(
            buildSwapParams(token, swapAmount)
        );
        emit TokensDistributed(token, block.timestamp);
        distributeBaseToken();
    }

    function distributeBaseToken() public {
        IERC20 _baseToken = baseToken;
        uint256 balance = _baseToken.balanceOf(address(this));
        require(balance != 0, "nothing to distribute");
        uint256 baseTokenReceiverCount = baseTokenReceiver.length;
        uint256 _totalSharesBaseReceiver = totalSharesBaseReceiver;

        for(uint256 i = 0; i < baseTokenReceiverCount; i++) {
            Shareholder storage shareholder = baseTokenReceiver[i];
            uint256 transferAmount = balance * shareholder.shares / _totalSharesBaseReceiver;
            if(shareholder.account == address(0)) {
                baseTokenController.burn(transferAmount);
                continue;
            }
            _baseToken.safeTransfer(
                shareholder.account, 
                transferAmount
            );
            if(shareholder.toBeNotified){
                require(
                    IShareholder(shareholder.account)
                        .notifyShareholder(address(_baseToken), transferAmount),
                    "callback failed"
                );
            }
        }
        emit TokensDistributed(address(_baseToken), block.timestamp);
    }

    function burnTokensFromBridge(bytes[] memory proofs) public {
        uint256 balanceBefore = baseToken.balanceOf(address(this));
        for(uint256 i = 0; i < proofs.length; i++) {
            polygonBridgeRoot.exit(proofs[i]);
        }
        uint256 burnAmount = baseToken.balanceOf(address(this)) - balanceBefore;
        baseTokenController.burn(burnAmount);
    }

    //// owner functionality ////
    function addRawTokenReceiver(Shareholder memory shareholder) public onlyOwner {
        require(shareholder.account != address(0), "raw receiver cannot be 0 address");
        totalShares += shareholder.shares;
        rawTokenReceiver.push(shareholder);
        emit ShareholderAdded(shareholder.account, true, shareholder.shares);
    }

    function addBaseTokenReceiver(Shareholder memory shareholder) public onlyOwner {
        totalShares += shareholder.shares;
        totalSharesBaseReceiver += shareholder.shares;
        baseTokenReceiver.push(shareholder);
        emit ShareholderAdded(shareholder.account, false, shareholder.shares);
    }

    function updateRawTokenReceiver(uint256 index, Shareholder memory shareholder) public onlyOwner {
        require(shareholder.account != address(0), "raw receiver cannot be 0 address");
        require(rawTokenReceiver.length > index, "raw receiver does not exist");
        totalShares = totalShares + shareholder.shares - rawTokenReceiver[index].shares;
        rawTokenReceiver[index] = shareholder;
    }
    
    function updateBaseTokenReceiver(uint256 index, Shareholder memory shareholder) public onlyOwner {
        require(baseTokenReceiver.length > index, "raw receiver does not exist");
        totalShares = totalShares + shareholder.shares - baseTokenReceiver[index].shares;
        totalSharesBaseReceiver = totalSharesBaseReceiver + shareholder.shares - baseTokenReceiver[index].shares;
        baseTokenReceiver[index] = shareholder;
    }

    function removeRawTokenReceiver(uint256 index) public onlyOwner {
        Shareholder storage shareholder = rawTokenReceiver[index];
        totalShares -= shareholder.shares;
        uint256 lastIndex = rawTokenReceiver.length - 1;
        if(index != lastIndex) {
            Shareholder memory lastShareholder = rawTokenReceiver[lastIndex];
            rawTokenReceiver[index] = lastShareholder;            
        }
        rawTokenReceiver.pop();
        emit ShareholderRemoved(shareholder.account, true, shareholder.shares);
    }

    function removeBaseTokenReceiver(uint256 index) public onlyOwner {
        uint256 shares = baseTokenReceiver[index].shares;
        totalShares -= shares;
        totalSharesBaseReceiver -= shares;
        uint256 lastIndex = baseTokenReceiver.length - 1;
        if(index != lastIndex) {
            Shareholder memory lastShareholder = baseTokenReceiver[lastIndex];
            baseTokenReceiver[index] = lastShareholder;            
        }
        baseTokenReceiver.pop();
        emit ShareholderRemoved(baseTokenReceiver[index].account, false, shares);
    }

    function setSwappingPath(address token, bytes memory path) public onlyOwner {
        require(token != address(baseToken), "cannot set path for base token");
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        _swappingPaths[token] = path;
    }

    function setBaseTokenController(ITokenController newController) external onlyOwner {
        baseTokenController = newController;
    }

    //// internal ////

    function buildSwapParams(address token, uint256 amount) 
        internal
        view
        returns(ISwapRouter.ExactInputParams memory)
    {
        return ISwapRouter.ExactInputParams(
            _swappingPaths[token],
            address(this),
            block.timestamp,
            amount,
            0
        );
    }

    //// view ////

    function balanceOfToken(address token) public view returns(uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function getSwappingPathForToken(address token) public view returns(bytes memory) {
        return _swappingPaths[token];
    }

    function getBaseTokenReceiver(uint256 index) public view returns(Shareholder memory) {
        return baseTokenReceiver[index];
    }

    function getBaseTokenReceiverCount() public view returns(uint256) {
        return baseTokenReceiver.length;
    }

    function getRawTokenReceiver(uint256 index) public view returns(Shareholder memory) {
        return rawTokenReceiver[index];
    }

    fallback() external payable {}

    //// EVENTS ////

    event ShareholderAdded(
        address indexed account,
        bool indexed isRawReceiver,
        uint256 shares
    );
    event ShareholderRemoved(address indexed account, bool indexed isRawReceiver, uint256 shares);
    event ShareholderUpdated(address indexed account, bool indexed isRawReceiver, uint256 shares);

    event TokensDistributed(address indexed token, uint256 indexed timestamp);
}