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

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint amount) external;
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

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
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
    /**********************************************************************************************
    ** Immutable router addresses for different DEXes:
    ** - uniswapV2Router: Uniswap V2 router
    ** - sushiV2Router: SushiSwap router (follows Uniswap V2 interface)
    ** - uniswapV3Router: Uniswap V3 router
    ** - velodromeRouter: Velodrome router
    ** 
    ** WETH: Wrapped Ether contract
    ** ETH: Constant address used to represent native ETH in transactions
    **********************************************************************************************/
    IUniswapV2Router02 public immutable uniswapV2Router;
    IUniswapV2Router02 public immutable sushiV2Router;
    IV3SwapRouter public immutable uniswapV3Router;
    IVelodromeRouter public immutable velodromeRouter;
    IWETH public immutable WETH;
    address private constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    
    /**********************************************************************************************
    ** Fee-related variables:
    ** - feeRecipient: Address that receives the fees
    ** - feePercentage: Current fee percentage (0 to 1000, representing 0% to 10%)
    ** - FEE_DENOMINATOR: Denominator for fee calculations (10000 for basis points)
    ** - MAX_FEE_PERCENTAGE: Maximum allowed fee percentage (10%)
    **********************************************************************************************/
    address public feeRecipient;
    uint256 public feePercentage;
    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_PERCENTAGE = 1000;

    /**********************************************************************************************
    ** owner: Address of the contract owner, who has special privileges
    **********************************************************************************************/
    address public owner;

    /**********************************************************************************************
    ** DEX: Enumeration of supported decentralized exchanges
    ** This allows for easy identification and routing of swaps to the correct DEX
    **********************************************************************************************/
    enum DEX { UNI_V2, SUSHI_V2, UNI_V3, VELODROME }

    /**********************************************************************************************
    ** SwapParams: Struct containing all necessary parameters for a multi-hop swap
    ** - path: Array of token addresses representing the swap path
    ** - amountIn: Amount of input tokens to swap
    ** - amountOutMin: Minimum amount of output tokens to receive (slippage protection)
    ** - recipient: Address to receive the swapped tokens (if 0, defaults to msg.sender)
    ** - dex: The DEX to use for this swap
    ** - fees: Array of fee tiers for Uniswap V3 swaps
    ** - stables: Array of booleans indicating if each hop uses a stable pool (for Velodrome)
    ** - factories: Array of factory addresses for each hop (for Velodrome)
    **********************************************************************************************/
    struct SwapParams {
        address[] path;
        uint256 amountIn;
        uint256 amountOutMin;
        address recipient;
        DEX dex;
        uint24[] fees;
        bool[] stables;
        address[] factories;
    }

    /**********************************************************************************************
    ** Swap event: Emitted after each successful swap
    ** Provides detailed information about the swap for off-chain tracking and analysis
    **********************************************************************************************/
    event Swap(
        address indexed user,
        address[] path,
        uint256 amountIn,
        uint256 amountOut,
        DEX dex
    );

    /**********************************************************************************************
    ** Constructor: Initializes the contract with necessary addresses
    ** Sets up router addresses, WETH address, initial fee recipient, and owner
    **********************************************************************************************/
    constructor(
        address _uniswapV2Router,
        address _sushiV2Router,
        address _uniswapV3Router,
        address _velodromeRouter,
        address _weth,
        address _feeRecipient
    ) {
        uniswapV2Router = IUniswapV2Router02(_uniswapV2Router);
        sushiV2Router = IUniswapV2Router02(_sushiV2Router);
        uniswapV3Router = IV3SwapRouter(_uniswapV3Router);
        velodromeRouter = IVelodromeRouter(_velodromeRouter);
        WETH = IWETH(_weth);
        feeRecipient = _feeRecipient;
        owner = msg.sender;
        feePercentage = 0; // Initially set to 0%
    }

    /**********************************************************************************************
    ** onlyOwner: Modifier to restrict access to owner-only functions
    **********************************************************************************************/
    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    /**********************************************************************************************
    ** setFeeRecipient: Allows the owner to change the fee recipient address
    **********************************************************************************************/
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
    }

    /**********************************************************************************************
    ** setFeePercentage: Allows the owner to change the fee percentage
    ** Ensures the new fee doesn't exceed the maximum allowed percentage
    **********************************************************************************************/
    function setFeePercentage(uint256 _feePercentage) external onlyOwner {
        require(_feePercentage <= MAX_FEE_PERCENTAGE, "Fee percentage too high");
        feePercentage = _feePercentage;
    }

    /**********************************************************************************************
    ** transferOwnership: Allows the current owner to transfer control of the contract to a new owner
    **********************************************************************************************/
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner is the zero address");
        owner = newOwner;
    }

    /**********************************************************************************************
    ** multicall: Main function to perform multiple multi-hop swaps in a single transaction
    ** - Iterates through the provided swap parameters
    ** - Calculates and deducts fees
    ** - Performs the multi-hop swaps using the appropriate DEX
    ** - Emits Swap events for each successful complete swap
    ** - Refunds any unused ETH
    **********************************************************************************************/
    function multicall(SwapParams[] calldata params) external payable {
        uint256 ethValue = msg.value;
        
        for (uint i = 0; i < params.length; i++) {
            SwapParams memory swap = params[i];
            
            uint256 feeAmount = (swap.amountIn * feePercentage) / FEE_DENOMINATOR;
            uint256 amountToSwap = swap.amountIn - feeAmount;
            
            if (swap.path[0] == ETH) {
                require(ethValue >= swap.amountIn, "Insufficient ETH sent");
                ethValue -= swap.amountIn;
                
                if (feeAmount > 0) {
                    payable(feeRecipient).transfer(feeAmount);
                }
                
                WETH.deposit{value: amountToSwap}();
            } else {
                IERC20(swap.path[0]).transferFrom(msg.sender, address(this), swap.amountIn);
                
                if (feeAmount > 0) {
                    IERC20(swap.path[0]).transfer(feeRecipient, feeAmount);
                }
                
                IERC20(swap.path[0]).approve(_getRouterAddress(swap.dex), amountToSwap);
            }

            uint256 amountOut;
            if (swap.dex == DEX.UNI_V3) {
                amountOut = _swapV3(swap, amountToSwap);
            } else if (swap.dex == DEX.VELODROME) {
                amountOut = _swapVelodrome(swap, amountToSwap);
            } else {
                amountOut = _swapV2(swap, amountToSwap);
            }

            require(amountOut >= swap.amountOutMin, "Insufficient output amount");
            emit Swap(msg.sender, swap.path, amountToSwap, amountOut, swap.dex);
        }
        
        if (ethValue > 0) {
            payable(msg.sender).transfer(ethValue);
        }
    }

    /**********************************************************************************************
    ** _swapV2: Internal function to perform multi-hop swaps on Uniswap V2 or SushiSwap
    ** - Handles ETH and token swaps
    ** - Uses the built-in multi-hop functionality of V2 routers
    **********************************************************************************************/
    function _swapV2(SwapParams memory swap, uint256 amountToSwap) internal returns (uint256) {
        IUniswapV2Router02 router = (swap.dex == DEX.UNI_V2) ? uniswapV2Router : sushiV2Router;

        if (swap.path[0] == ETH) {
            uint[] memory amounts = router.swapExactETHForTokens{value: amountToSwap}(
                swap.amountOutMin,
                swap.path,
                swap.recipient != address(0) ? swap.recipient : address(this),
                block.timestamp
            );
            return amounts[amounts.length - 1];
        } else if (swap.path[swap.path.length - 1] == ETH) {
            uint[] memory amounts = router.swapExactTokensForETH(
                amountToSwap,
                swap.amountOutMin,
                swap.path,
                swap.recipient != address(0) ? swap.recipient : address(this),
                block.timestamp
            );
            return amounts[amounts.length - 1];
        } else {
            uint[] memory amounts = router.swapExactTokensForTokens(
                amountToSwap,
                swap.amountOutMin,
                swap.path,
                swap.recipient != address(0) ? swap.recipient : address(this),
                block.timestamp
            );
            return amounts[amounts.length - 1];
        }
    }

    /**********************************************************************************************
    ** _swapV3: Internal function to perform multi-hop swaps on Uniswap V3
    ** - Uses the exactInput function for efficient multi-hop swaps
    ** - Encodes the path with fees for V3 swaps
    **********************************************************************************************/
    function _swapV3(SwapParams memory swap, uint256 amountToSwap) internal returns (uint256) {
        bytes memory path = _encodePath(swap.path, swap.fees);

        IV3SwapRouter.ExactInputParams memory params = IV3SwapRouter.ExactInputParams({
            path: path,
            recipient: swap.recipient != address(0) ? swap.recipient : address(this),
            amountIn: amountToSwap,
            amountOutMinimum: swap.amountOutMin
        });

        return uniswapV3Router.exactInput(params);
    }

    /**********************************************************************************************
    ** _swapVelodrome: Internal function to perform multi-hop swaps on Velodrome
    ** - Constructs the route array for Velodrome swaps
    ** - Handles multi-hop swaps by creating multiple route steps
    **********************************************************************************************/
    function _swapVelodrome(SwapParams memory swap, uint256 amountToSwap) internal returns (uint256) {
        IVelodromeRouter.Route[] memory route = new IVelodromeRouter.Route[](swap.path.length - 1);
        for (uint i = 0; i < swap.path.length - 1; i++) {
            route[i] = IVelodromeRouter.Route({
                from: swap.path[i],
                to: swap.path[i + 1],
                stable: swap.stables[i],
                factory: swap.factories[i]
            });
        }

        uint[] memory amounts = velodromeRouter.swapExactTokensForTokens(
            amountToSwap,
            swap.amountOutMin,
            route,
            swap.recipient != address(0) ? swap.recipient : address(this),
            block.timestamp
        );

        return amounts[amounts.length - 1];
    }

    /**********************************************************************************************
    ** _encodePath: Internal function to encode the swap path for Uniswap V3
    ** - Combines token addresses and fee values into a single bytes value
    ** - Required format for Uniswap V3 swaps
    **********************************************************************************************/
    function _encodePath(address[] memory _path, uint24[] memory _fees) internal pure returns (bytes memory path) {
        path = abi.encodePacked(_path[0]);
        for (uint256 i = 0; i < _fees.length; i++) {
            path = abi.encodePacked(path, _fees[i], _path[i + 1]);
        }
    }

    /**********************************************************************************************
    ** _getRouterAddress: Internal function to get the appropriate router address for a given DEX
    **********************************************************************************************/
    function _getRouterAddress(DEX dex) internal view returns (address) {
        if (dex == DEX.UNI_V2) return address(uniswapV2Router);
        if (dex == DEX.SUSHI_V2) return address(sushiV2Router);
        if (dex == DEX.UNI_V3) return address(uniswapV3Router);
        if (dex == DEX.VELODROME) return address(velodromeRouter);
        revert("Invalid DEX");
    }

    /**********************************************************************************************
    ** receive: Fallback function to receive ETH
    ** This allows the contract to receive ETH, which is necessary for certain swap operations
    **********************************************************************************************/
    receive() external payable {}
}