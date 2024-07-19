// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/IERC20.sol";

contract BasketFactory {
    /**********************************************************************************************
    ** BasketInfo struct stores all relevant information about a basket:
    ** - name: A human-readable identifier for the basket
    ** - assets: An array of token addresses that compose the basket
    ** - allocations: Corresponding allocations for each asset (in basis points, i.e., 100 = 1%)
    ** - creator: Address of the user who created the basket
    ** - creationTime: Timestamp of when the basket was created
    ** - rating: Current average rating of the basket (1-5)
    ** - totalRatings: Number of ratings the basket has received
    ** - endorsed: Boolean indicating if the basket is endorsed by the contract owner
    ** 
    ** This structure allows for efficient storage and retrieval of all basket-related data.
    **********************************************************************************************/
    struct BasketInfo {
        string name;
        address[] assets;
        uint256[] allocations;
        address creator;
        uint256 creationTime;
        uint256 rating;
        uint256 totalRatings;
        bool endorsed;
    }

    /**********************************************************************************************
    ** Events are emitted when key actions occur in the contract. They serve multiple purposes:
    ** - Provide a way for external systems to track important contract activities
    ** - Enable efficient indexing and querying of contract state changes
    ** - Facilitate updates in front-end applications
    ** 
    ** BasketCreated: Emitted when a new basket is created
    ** BasketRated: Emitted when a user rates a basket
    ** BasketEndorsed: Emitted when a basket's endorsement status changes
    ** OwnershipTransferred: Emitted when contract ownership changes
    **********************************************************************************************/
    event BasketCreated(uint256 indexed basketId, string name, address indexed creator);
    event BasketRated(uint256 indexed basketId, address indexed rater, uint256 rating);
    event BasketEndorsed(uint256 indexed basketId, bool endorsed);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**********************************************************************************************
    ** Main storage variables:
    ** - baskets: A mapping from basket ID to BasketInfo, storing all created baskets
    ** - basketCount: Total number of baskets created, also used as the next basket ID
    ** - endorsedBaskets: An array of IDs of endorsed baskets for efficient retrieval
    ** 
    ** These variables form the core state of the contract, allowing for creation, tracking,
    ** and retrieval of baskets.
    **********************************************************************************************/
    mapping(uint256 => BasketInfo) public baskets;
    uint256 public basketCount;
    uint256[] public endorsedBaskets;

    /**********************************************************************************************
    ** userRatings: A nested mapping to store individual user ratings for each basket
    ** 
    ** Structure: userRatings[userAddress][basketId] = rating
    ** 
    ** This allows us to:
    ** 1. Keep track of each user's rating for every basket
    ** 2. Prevent duplicate ratings from the same user
    ** 3. Allow users to update their ratings
    **********************************************************************************************/
    mapping(address => mapping(uint256 => uint256)) public userRatings;

    /**********************************************************************************************
    ** Constants define the minimum and maximum number of tokens allowed in a basket:
    ** - MIN_TOKENS: Ensures that each basket has at least 2 tokens for diversification
    ** - MAX_TOKENS: Limits the maximum number of tokens to 10 for gas efficiency and usability
    ** 
    ** These limits help maintain a balance between flexibility and practical constraints.
    **********************************************************************************************/
    uint256 public constant MIN_TOKENS = 2;
    uint256 public constant MAX_TOKENS = 10;

    /**********************************************************************************************
    ** owner: Address of the contract owner
    ** 
    ** The owner has special privileges:
    ** - Can endorse or unendorse baskets
    ** - Can transfer ownership to another address
    ** 
    ** This allows for some centralized control over basket curation while keeping basket
    ** creation open to all users.
    **********************************************************************************************/
    address public owner;

    /**********************************************************************************************
    ** onlyOwner modifier restricts certain functions to be callable only by the contract owner.
    ** 
    ** This is used for administrative functions like endorsing baskets and transferring ownership.
    ** It helps maintain the security and integrity of privileged operations.
    **********************************************************************************************/
    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not the owner");
        _;
    }

    /**********************************************************************************************
    ** Constructor sets the initial owner to the contract deployer.
    ** 
    ** This is called once when the contract is first deployed. It sets up the initial state
    ** of the contract by assigning the deploying address as the owner.
    **********************************************************************************************/
    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /**********************************************************************************************
    ** transferOwnership allows the current owner to transfer control of the contract to a new owner.
    ** 
    ** This function:
    ** 1. Can only be called by the current owner (enforced by onlyOwner modifier)
    ** 2. Requires the new owner address to be non-zero to prevent accidental loss of ownership
    ** 3. Updates the owner state variable
    ** 4. Emits an OwnershipTransferred event
    ** 
    ** This function is crucial for maintaining flexible control over the contract, allowing
    ** for ownership changes when necessary (e.g., key rotation, change in project structure).
    **********************************************************************************************/
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "New owner is the zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /**********************************************************************************************
    ** createBasket allows users to create a new basket with specified assets and allocations.
    ** 
    ** This function:
    ** 1. Validates input:
    **    - Ensures the number of assets matches the number of allocations
    **    - Checks that the number of tokens is within allowed limits
    **    - Verifies that allocations sum to 100% (10000 basis points)
    ** 2. Creates a new BasketInfo struct with the provided data and some defaults
    ** 3. Stores the new basket in the baskets mapping
    ** 4. Increments the basketCount
    ** 5. Emits a BasketCreated event
    ** 
    ** This is the core function for basket creation, allowing users to define custom asset allocations.
    **********************************************************************************************/
    function createBasket(
        string memory _name,
        address[] memory _assets,
        uint256[] memory _allocations
    ) external returns (uint256) {
        require(_assets.length == _allocations.length, "Assets and allocations length mismatch");
        require(_assets.length >= MIN_TOKENS && _assets.length <= MAX_TOKENS, "Invalid number of tokens");
        
        uint256 totalAllocation = 0;
        for (uint i = 0; i < _allocations.length; i++) {
            totalAllocation += _allocations[i];
        }
        require(totalAllocation == 10000, "Total allocation must be 10000 (100%)");

        uint256 basketId = basketCount;
        basketCount++;

        baskets[basketId] = BasketInfo({
            name: _name,
            assets: _assets,
            allocations: _allocations,
            creator: msg.sender,
            creationTime: block.timestamp,
            rating: 0,
            totalRatings: 0,
            endorsed: false
        });

        emit BasketCreated(basketId, _name, msg.sender);

        return basketId;
    }

    /**********************************************************************************************
    ** rateBasket allows users to rate a basket or update their existing rating.
    ** 
    ** This function:
    ** 1. Validates input:
    **    - Ensures the basket exists
    **    - Checks that the rating is within the valid range (1-5)
    ** 2. Retrieves the user's previous rating for this basket (if any)
    ** 3. Updates the user's rating in the userRatings mapping
    ** 4. Updates the basket's overall rating:
    **    - If it's a new rating, it's added to the total
    **    - If it's updating an existing rating, the old rating is subtracted and the new one added
    ** 5. Emits a BasketRated event
    ** 
    ** This function allows for community-driven quality assessment of baskets.
    **********************************************************************************************/
    function rateBasket(uint256 _basketId, uint256 _rating) external {
        require(_basketId < basketCount, "Basket does not exist");
        require(_rating >= 1 && _rating <= 5, "Rating must be between 1 and 5");

        BasketInfo storage basket = baskets[_basketId];
        uint256 oldRating = userRatings[msg.sender][_basketId];
        userRatings[msg.sender][_basketId] = _rating;

        if (oldRating == 0) {
            basket.rating = (basket.rating * basket.totalRatings + _rating) / (basket.totalRatings + 1);
            basket.totalRatings++;
        } else {
            basket.rating = (basket.rating * basket.totalRatings - oldRating + _rating) / basket.totalRatings;
        }

        emit BasketRated(_basketId, msg.sender, _rating);
    }

    /**********************************************************************************************
    ** endorseBasket allows the owner to endorse or unendorse a basket.
    ** 
    ** This function:
    ** 1. Can only be called by the contract owner (enforced by onlyOwner modifier)
    ** 2. Validates that the specified basket exists
    ** 3. If endorsing:
    **    - Adds the basket ID to the endorsedBaskets array if it's not already endorsed
    ** 4. If unendorsing:
    **    - Removes the basket ID from the endorsedBaskets array
    ** 5. Updates the endorsed status in the basket's info
    ** 6. Emits a BasketEndorsed event
    ** 
    ** This function allows for curation of baskets, highlighting those deemed high-quality or trustworthy.
    **********************************************************************************************/
    function endorseBasket(uint256 _basketId, bool _endorsed) external onlyOwner {
        require(_basketId < basketCount, "Basket does not exist");
        BasketInfo storage basket = baskets[_basketId];
        
        if (_endorsed && !basket.endorsed) {
            endorsedBaskets.push(_basketId);
            basket.endorsed = true;
        } else if (!_endorsed && basket.endorsed) {
            for (uint i = 0; i < endorsedBaskets.length; i++) {
                if (endorsedBaskets[i] == _basketId) {
                    endorsedBaskets[i] = endorsedBaskets[endorsedBaskets.length - 1];
                    endorsedBaskets.pop();
                    break;
                }
            }
            basket.endorsed = false;
        }
        
        emit BasketEndorsed(_basketId, _endorsed);
    }

    /**********************************************************************************************
    ** getBasketInfo retrieves detailed information about a specific basket.
    ** 
    ** This function:
    ** 1. Validates that the specified basket exists
    ** 2. Returns the entire BasketInfo struct for the given basket ID
    ** 
    ** This allows external contracts or off-chain applications to fetch complete basket details.
    **********************************************************************************************/
    function getBasketInfo(uint256 _basketId) external view returns (BasketInfo memory) {
        require(_basketId < basketCount, "Basket does not exist");
        return baskets[_basketId];
    }

    /**********************************************************************************************
    ** getBasketsByPage retrieves a paginated list of all baskets.
    ** 
    ** This function:
    ** 1. Validates input:
    **    - Ensures the page size is greater than 0
    **    - Checks that the requested page is within range
    ** 2. Calculates the start and end indices for the requested page
    ** 3. Creates an array of BasketInfo structs for the baskets on the requested page
    ** 4. Returns this array
    ** 
    ** Pagination is crucial for efficient data retrieval, especially as the number of baskets grows.
    ** This function allows for scalable basket discovery and browsing.
    **********************************************************************************************/
    function getBasketsByPage(uint256 _page, uint256 _pageSize) external view returns (BasketInfo[] memory) {
        require(_pageSize > 0, "Page size must be greater than 0");
        uint256 startIndex = _page * _pageSize;
        require(startIndex < basketCount, "Page out of range");

        uint256 endIndex = startIndex + _pageSize;
        if (endIndex > basketCount) {
            endIndex = basketCount;
        }

        BasketInfo[] memory pageBaskets = new BasketInfo[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            pageBaskets[i - startIndex] = baskets[i];
        }

        return pageBaskets;
    }

    /**********************************************************************************************
    ** getEndorsedBasketsByPage retrieves a paginated list of only the endorsed baskets.
    ** 
    ** This function:
    ** 1. Validates input:
    **    - Ensures the page size is greater than 0
    **    - Checks that the requested page is within range of endorsed baskets
    ** 2. Calculates the start and end indices for the requested page
    ** 3. Creates an array of BasketInfo structs for the endorsed baskets on the requested page
    ** 4. Returns this array
    ** 
    ** This function allows for efficient retrieval of curated or recommended baskets, which can be
    ** particularly useful for highlighting quality baskets to users.
    **********************************************************************************************/
    function getEndorsedBasketsByPage(uint256 _page, uint256 _pageSize) external view returns (BasketInfo[] memory) {
        require(_pageSize > 0, "Page size must be greater than 0");
        uint256 startIndex = _page * _pageSize;
        require(startIndex < endorsedBaskets.length, "Page out of range");

        uint256 endIndex = startIndex + _pageSize;
        if (endIndex > endorsedBaskets.length) {
            endIndex = endorsedBaskets.length;
        }

        BasketInfo[] memory pageBaskets = new BasketInfo[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            pageBaskets[i - startIndex] = baskets[endorsedBaskets[i]];
        }

        return pageBaskets;
    }

    /**********************************************************************************************
    ** getEndorsedBasketsCount returns the total number of endorsed baskets.
    ** 
    ** This function:
    ** 1. Simply returns the length of the endorsedBaskets array
    ** 
    ** This is useful for:
    ** - Pagination of endorsed baskets in frontend applications
    ** - Quickly checking how many baskets are currently endorsed
    ** - Allowing users to see the size of the curated basket list
    **********************************************************************************************/
    function getEndorsedBasketsCount() external view returns (uint256) {
        return endorsedBaskets.length;
    }
}