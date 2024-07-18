// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
}

interface IV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IVelodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        Route[] calldata routes,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactETHForTokens(
        uint amountOutMin,
        Route[] calldata routes,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        Route[] calldata routes,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

contract MultiSwapRouter {
    IUniswapV2Router02 public immutable uniswapV2Router;
    IUniswapV2Router02 public immutable sushiV2Router;
    IV3SwapRouter public immutable uniswapV3Router;
    IVelodromeRouter public immutable velodromeRouter;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // Mainnet WETH address
    
    address public feeRecipient;
    uint256 public feePercentage; // Fee percentage (0 to 1000, representing 0% to 10%)
    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_PERCENTAGE = 1000; // 10%

    address public owner;

    enum DEX { UNI_V2, SUSHI_V2, UNI_V3, VELODROME }

    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOutMin;
        DEX dex;
        // V3 specific params
        uint24 fee;
        address recipient;
        uint160 sqrtPriceLimitX96;
        // Velodrome specific params
        bool stable;
        address factory;
    }

    constructor(
        address _uniswapV2Router,
        address _sushiV2Router,
        address _uniswapV3Router,
        address _velodromeRouter,
        address _feeRecipient
    ) {
        uniswapV2Router = IUniswapV2Router02(_uniswapV2Router);
        sushiV2Router = IUniswapV2Router02(_sushiV2Router);
        uniswapV3Router = IV3SwapRouter(_uniswapV3Router);
        velodromeRouter = IVelodromeRouter(_velodromeRouter);
        feeRecipient = _feeRecipient;
        owner = msg.sender;
        feePercentage = 0; // Initially set to 0%
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
    }

    function setFeePercentage(uint256 _feePercentage) external onlyOwner {
        require(_feePercentage <= MAX_FEE_PERCENTAGE, "Fee percentage too high");
        feePercentage = _feePercentage;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner is the zero address");
        owner = newOwner;
    }

    function multicall(SwapParams[] calldata params) external payable {
        uint256 ethValue = msg.value;
        
        for (uint i = 0; i < params.length; i++) {
            SwapParams memory swap = params[i];
            
            uint256 feeAmount = (swap.amountIn * feePercentage) / FEE_DENOMINATOR;
            uint256 amountToSwap = swap.amountIn - feeAmount;
            
            if (swap.tokenIn != WETH) {
                IERC20(swap.tokenIn).transferFrom(msg.sender, address(this), swap.amountIn);
                
                if (feeAmount > 0) {
                    IERC20(swap.tokenIn).transfer(feeRecipient, feeAmount);
                }
                
                IERC20(swap.tokenIn).approve(_getRouterAddress(swap.dex), amountToSwap);
            } else {
                require(ethValue >= swap.amountIn, "Insufficient ETH sent");
                ethValue -= swap.amountIn;
                
                if (feeAmount > 0) {
                    payable(feeRecipient).transfer(feeAmount);
                }
            }

            if (swap.dex == DEX.UNI_V3) {
                _swapV3(swap, amountToSwap);
            } else if (swap.dex == DEX.VELODROME) {
                _swapVelodrome(swap, amountToSwap);
            } else {
                _swapV2(swap, amountToSwap);
            }
        }
        
        if (ethValue > 0) {
            payable(msg.sender).transfer(ethValue);
        }
    }

    function _swapV2(SwapParams memory swap, uint256 amountToSwap) internal {
        IUniswapV2Router02 router = (swap.dex == DEX.UNI_V2) ? uniswapV2Router : sushiV2Router;

        address[] memory path = new address[](2);
        path[0] = swap.tokenIn;
        path[1] = swap.tokenOut;

        if (swap.tokenIn == WETH) {
            router.swapExactETHForTokens{value: amountToSwap}(
                swap.amountOutMin,
                path,
                swap.recipient != address(0) ? swap.recipient : msg.sender,
                block.timestamp
            );
        } else if (swap.tokenOut == WETH) {
            router.swapExactTokensForETH(
                amountToSwap,
                swap.amountOutMin,
                path,
                swap.recipient != address(0) ? swap.recipient : msg.sender,
                block.timestamp
            );
        } else {
            router.swapExactTokensForTokens(
                amountToSwap,
                swap.amountOutMin,
                path,
                swap.recipient != address(0) ? swap.recipient : msg.sender,
                block.timestamp
            );
        }
    }

    function _swapV3(SwapParams memory swap, uint256 amountToSwap) internal {
        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: swap.tokenIn,
            tokenOut: swap.tokenOut,
            fee: swap.fee,
            recipient: swap.recipient != address(0) ? swap.recipient : msg.sender,
            amountIn: amountToSwap,
            amountOutMinimum: swap.amountOutMin,
            sqrtPriceLimitX96: swap.sqrtPriceLimitX96
        });

        if (swap.tokenIn == WETH) {
            uniswapV3Router.exactInputSingle{value: amountToSwap}(params);
        } else {
            uniswapV3Router.exactInputSingle(params);
        }
    }

    function _swapVelodrome(SwapParams memory swap, uint256 amountToSwap) internal {
        IVelodromeRouter.Route[] memory route = new IVelodromeRouter.Route[](1);
        route[0] = IVelodromeRouter.Route({
            from: swap.tokenIn,
            to: swap.tokenOut,
            stable: swap.stable,
            factory: swap.factory
        });

        if (swap.tokenIn == WETH) {
            velodromeRouter.swapExactETHForTokens{value: amountToSwap}(
                swap.amountOutMin,
                route,
                swap.recipient != address(0) ? swap.recipient : msg.sender,
                block.timestamp
            );
        } else if (swap.tokenOut == WETH) {
            velodromeRouter.swapExactTokensForETH(
                amountToSwap,
                swap.amountOutMin,
                route,
                swap.recipient != address(0) ? swap.recipient : msg.sender,
                block.timestamp
            );
        } else {
            velodromeRouter.swapExactTokensForTokens(
                amountToSwap,
                swap.amountOutMin,
                route,
                swap.recipient != address(0) ? swap.recipient : msg.sender,
                block.timestamp
            );
        }
    }

    function _getRouterAddress(DEX dex) internal view returns (address) {
        if (dex == DEX.UNI_V2) return address(uniswapV2Router);
        if (dex == DEX.SUSHI_V2) return address(sushiV2Router);
        if (dex == DEX.UNI_V3) return address(uniswapV3Router);
        if (dex == DEX.VELODROME) return address(velodromeRouter);
        revert("Invalid DEX");
    }

    receive() external payable {}
}