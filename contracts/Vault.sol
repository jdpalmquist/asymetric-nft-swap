// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";


contract Vault is IERC721Receiver {

    //EVENTS
    //======
    event TokenTransferred(address indexed operator, address indexed from, uint256 indexed nftID, bytes data);

    //ADMIN
    //=====
    bool private paused;
    uint256 private fee;
    address private admin;
    address private nftContractAddr;
    IERC721 private nftContract;

    //BROADCAST
    //=========
    uint256 public openTrades;
    
    //LISTS
    //=====
    //note: Global resource for the contract!!
    //      lists are disposable, but never deleted
    //      make new lists and update the index when needed
    uint256 private l;
    // list id => list of assetIDs
    mapping(uint256 => uint256[]) private list;

    //ASSETS
    //======
    uint256 private h;
    // nft id => owner address
    mapping(uint256 => address) private nfts;
    // nft id => isLocked
    mapping(uint256 => bool) private nftLocked;
    // address => total of all coins on your account
    mapping(address => uint256) private balance;

    //APPROVALS
    //=========
    // nft id => is approved for all transfers
    mapping(address => bool) private approvedForAll;

    //COLLECTIONS
    //===========
    // address => bool
    mapping(address => bool) private hasAccount;
    // address => list id of current assets
    mapping(address => uint256) private myNfts;
    // address => list id of one or more nftIDs to be traded
    mapping(address => uint256) private myTrades;
    // myTradesID => address
    mapping(uint256 => address) private tradeMap;
    
    // myTradesID => list of pending offer IDs
    mapping(uint256 => uint256) private pendingOffers;
    // myOfferID => TradeID that caller offered
    mapping(uint256 => uint256) private offerPending;
    // address => list id of one or more assetIDs to be offered
    mapping(address => uint256) private myOffers;
    // myOffersID => address
    mapping(uint256 => address) private offerMap;
    
    // address => locked myTrades list
    mapping(address => uint256) private activeTrade;
    // address => locked myOffers list
    mapping(address => uint256) private activeOffer;
    // address => is my trade locked in?
    mapping(address => bool) private tradeLocked;
    // address => is my offer locked in?
    mapping(address => bool) private offerLocked;


    constructor(){
        admin = tx.origin; // contract owner
        fee = 1000000000000000000; // ex: 1 ETH
        l++; // make sure the zeroth list stays blank / empty
        openTrades = l; // opentrades is just a listID that points to a list of listIDs
        paused = true; // force the contract admin to set the address of the ERC721 Nfts contract
    }

    fallback() external {revert();}

    receive() external payable {revert();}


    /* ADMIN */

    function togglePause() external {
        require(tx.origin == admin, "!ADMIN");
        paused = !paused;
    }

    function setFee(uint256 _fee) external {
        require(tx.origin == admin, "!ADMIN");
        fee = _fee;
    }

    function setNftContractAddr(address _c) external {
        require(tx.origin == admin, "!ADMIN");
        nftContractAddr = _c; //verified ERC721 avax-dfk mainnet contract addr: 0xEb9B61B145D6489Be575D3603F4a704810e143dF
        nftContract = IERC721(nftContractAddr);
        paused = false;
    }

    function viewFee() external view returns (uint256) {
        return fee;
    }

    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function withdrawFunds() external payable {
        require(tx.origin == admin, "!ADMIN");
        payable(address(this)).transfer(address(this).balance);
    }


    /* ACCOUNTS */

    function isRegistered() external view returns (bool) {
        return hasAccount[tx.origin];
    }

    function makeAccount() external {
        require(!paused, "SYSPAUSE");
        require(!hasAccount[tx.origin], "ACCTEXST");
    
        l++;
        myNfts[tx.origin] = l;
        l++;
        myTrades[tx.origin] = l;
        l++;
        myOffers[tx.origin] = l;

        hasAccount[tx.origin] = true;        
    }


    /* ASSETS */

    function isApproved(uint256 nftID) public view nZ(nftID) returns (bool){
        //the system cannot be paused
        require(!paused, "SYSPAUSE");
        //caller must have an account
        require(hasAccount[tx.origin], "NOACCT");

        return address(this) == nftContract.getApproved(nftID);
    }

    function isApprovedForAll(address owner) public view returns (bool) {
        //the system cannot be paused
        require(!paused, "SYSPAUSE");
        //caller must have an account
        require(hasAccount[tx.origin], "NOACCT");
        //the owner cannot be the null addr
        require(owner != address(0), "0ADDR");

        return nftContract.isApprovedForAll(owner, address(this));
    }

    function uploadNft(uint256 nftID) external nZ(nftID) {
        //the system cannot be paused
        require(!paused, "SYSPAUSE");
        //caller must have an account
        require(hasAccount[tx.origin], "NOACCT");
        //block duplicates
        require(nfts[nftID] == address(0), "DUPLCATE");
        //is nftID approved for this contract?
        address apAddr = nftContract.getApproved(nftID);
        approvedForAll[tx.origin] = nftContract.isApprovedForAll(tx.origin, address(this));
        require(apAddr == address(this) || approvedForAll[tx.origin], "!APPROVD");

        //send nft to this contract
        nftContract.safeTransferFrom(tx.origin, address(this), nftID);
        //nftContract.transferFrom(tx.origin, address(this), nftID); //unsafe transfer
        
        //complete the record keeping...
        nfts[nftID] = tx.origin;
        list[myNfts[tx.origin]].push(nftID);
    }

    function viewMyNfts() external view returns (uint256[] memory) {
        require(hasAccount[tx.origin], "NOACCT");
        uint256 listID = myNfts[tx.origin];
        return list[listID];
    }

    function withdrawNft(uint256 nftID) external nZ(nftID) {
        require(hasAccount[tx.origin], "NOACCT");
        // the caller must be the owner
        require(nfts[nftID] == tx.origin, "!OWNER");
        // the asset must not be locked (in escrow)
        require(!nftLocked[nftID], "ESCROW");
        
        // send the asset to the owner address
        nftContract.safeTransferFrom(address(this), tx.origin, nftID);
        //nftContract.transferFrom(address(this), tx.origin, nftID); //unsafe transfer

        nfts[nftID] = address(0);

        //update the assets list
        uint256 myNftList = myNfts[tx.origin];
        l++;
        uint256 newListID = l;
        uint256 hID;
        for(uint256 i = 0; i < list[myNftList].length; i++){
            hID = list[myNftList][i];
            //exclude ID=0, and the removed Nft ID
            if(hID != 0 && hID != nftID){
                list[newListID].push(hID);
            }
        }
        myNfts[tx.origin] = newListID;
    }

    function queueNft(bool tradeTrueOfferFalse, uint256 nftID) external nZ(nftID) {
        require(!paused, "SYSPAUSE");
        require(hasAccount[tx.origin], "NOACCT");
        require(nfts[nftID] == tx.origin, "!OWNER");
        require(!nftLocked[nftID], "ESCROW");

        //remove the nft from the myNfts list
        l++;
        for(uint256 i = 0; i < list[myNfts[tx.origin]].length; i++){
            if(list[myNfts[tx.origin]][i] != nftID){
                list[l].push(list[myNfts[tx.origin]][i]);
            }
        }
        myNfts[tx.origin] = l;

        //push the nftID into the trade/offer list
        if(tradeTrueOfferFalse == true){
            //caller's trades bucket must be unlocked
            require(!tradeLocked[tx.origin], "TLOCKED");
            list[myTrades[tx.origin]].push(nftID);
        }
        else{
            //caller's offers bucket must be unlocked
            require(!offerLocked[tx.origin], "OLOCKED");
            list[myOffers[tx.origin]].push(nftID);
        }
        //lock the nft (forbid withdrawal)
        nftLocked[nftID] = true;
    }

    function dequeueNft(bool tradeTrueOfferFalse, uint256 nftID) external nZ(nftID) {
        require(hasAccount[tx.origin], "NOACCT");
        require(nfts[nftID] == tx.origin, "!OWNER");
        require(nftLocked[nftID], "!ESCROW");
        
        l++;
        if(tradeTrueOfferFalse){
            require(!tradeLocked[tx.origin], "TLOCKED");

            //remove the nftID from the myTrades list
            for(uint256 i = 0; i < list[myTrades[tx.origin]].length; i++){
                if(list[myTrades[tx.origin]][i] != nftID){
                    list[l].push(list[myTrades[tx.origin]][i]);
                }
            }
            myTrades[tx.origin] = l;
        }
        else{
            require(!offerLocked[tx.origin], "OLOCKED");
            
            //remove the dequeued nft from the myOffers list
            for(uint256 i = 0; i < list[myOffers[tx.origin]].length; i++){
                if(list[myOffers[tx.origin]][i] != nftID){
                    list[l].push(list[myOffers[tx.origin]][i]);
                }
            }
            myOffers[tx.origin] = l;
        }

        //add the dequeued nft back into the myNfts list
        list[myNfts[tx.origin]].push(nftID);
        //unlock the nft (allow withdrawal)
        nftLocked[nftID] = false;
    }

    function viewQueued(bool tradeTrueOfferFalse) external view returns (uint256[] memory) {
        require(hasAccount[tx.origin], "NOACCT");
        uint256 listID;
        if(tradeTrueOfferFalse){
            require(!tradeLocked[tx.origin], "TLOCKED");
            listID = myTrades[tx.origin];
        }
        else{
            require(!offerLocked[tx.origin], "OLOCKED");
            listID = myOffers[tx.origin];
        }
        return list[listID];
    }

        
    /* TRADES */

    function setTrade() external {
        require(hasAccount[tx.origin], "NOACCT");
        /*
            NOTE: this function toggles between publishing your trades bucket and rescinding that bucket
        */
        if(tradeLocked[tx.origin]){
            //unlock the caller's trade bucket
            //remove them from the openTrades list
            l++;
            uint nopt = l;
            for(uint256 i = 0; i < list[openTrades].length; i++){
                if(list[openTrades][i] != myTrades[tx.origin]){
                    list[nopt].push(list[openTrades][i]);
                }
            }
            //update the list of openTrades
            openTrades = nopt;
            activeTrade[tx.origin] = 0;
            tradeMap[myTrades[tx.origin]] = address(0);
        }
        else{
            require(!paused, "SYSPAUSE");
            //caller cannot push an empty list into an active state
            require(list[myTrades[tx.origin]].length > 0, "NOTRADES");
            //lock the caller's trade bucket
            //add them to the openTrades list
            list[openTrades].push(myTrades[tx.origin]);
            activeTrade[tx.origin] = myTrades[tx.origin];
            tradeMap[myTrades[tx.origin]] = tx.origin;
        }
        tradeLocked[tx.origin] = !tradeLocked[tx.origin];
    }

    function viewActiveTrade() external view returns (uint256[] memory) {
        require(hasAccount[tx.origin], "NOACCT");
        require(activeTrade[tx.origin] != 0, "T!ACTIVE");
        return list[activeTrade[tx.origin]];
    }

    function viewActiveTradeID() external view returns (uint256) {
        require(hasAccount[tx.origin], "NOACCT");
        require(activeTrade[tx.origin] != 0, "T!ACTIVE");
        return activeTrade[tx.origin];
    }

    function viewPendingOffers() external view returns (uint256[] memory) {
        require(hasAccount[tx.origin], "NOACCT");
        require(activeTrade[tx.origin] != 0, "T!ACTIVE");
        uint myPublishedTradeID = myTrades[tx.origin];
        uint listID = pendingOffers[myPublishedTradeID];
        return list[listID];
    }

    function acceptOffer(uint256 offerID) external payable nZ(offerID) {
        require(!paused, "SYSPAUSE");
        require(hasAccount[tx.origin], "NOACCT");
        require(tradeLocked[tx.origin], "T!ACTIVE");
        require(offerLocked[offerMap[offerID]], "O!ACTIVE");
        require(msg.value == fee, "!AMOUNT");
        
        uint256 nftID;
        address tAddr = tx.origin;
        address oAddr = offerMap[offerID];

        //trader assets => offer assets
        for(uint256 i = 0; i < list[myTrades[tx.origin]].length; i++){
            nftID = list[myTrades[tx.origin]][i];
            nfts[nftID] = oAddr;
            nftLocked[nftID] = false;
            list[myNfts[offerMap[offerID]]].push(nftID);
        }

        //offer assets => trader assets
        for(uint256 i = 0; i < list[myOffers[offerMap[offerID]]].length; i++){
            nftID = list[myOffers[offerMap[offerID]]][i];
            nfts[nftID] = tAddr;
            nftLocked[nftID] = false;
            list[myNfts[tx.origin]].push(nftID);
        }

        //remove the tradeID from the openTrades list
        l++;
        for(uint256 i = 0; i < list[openTrades].length; i++){
            if(list[openTrades][i] != activeTrade[tx.origin]){
                list[l].push(list[openTrades][i]);
            }            
        }
        openTrades = l;

        l++;
        myTrades[tx.origin] = l; //empty the trades bucket
        activeTrade[tx.origin] = 0;
        tradeLocked[tx.origin] = false; //unlock the trade bucket
        l++;
        myOffers[offerMap[offerID]] = l; //empty the offers bucket
        activeOffer[offerMap[offerID]] = 0;
        offerLocked[offerMap[offerID]] = false; //unlock the offer bucket
    }


    /* OFFERS */

    function setOffer(uint256 tradeID) external {
        require(hasAccount[tx.origin], "NOACCT");
        /*
            NOTE: this function toggles between publishing/rescinding your offer bucket
        */
        
        if(offerLocked[tx.origin]){
            //unlock offer    
            //remove the offer from the pending offers list
            l++;
            for(uint256 i = 0; i < list[pendingOffers[tradeID]].length; i++){
                if(list[pendingOffers[tradeID]][i] != myOffers[tx.origin]){
                    list[l].push(list[pendingOffers[tradeID]][i]);
                }
            }
            offerPending[activeOffer[tx.origin]] = 0;
            activeOffer[tx.origin] = 0;            
            offerMap[myOffers[tx.origin]] = address(0);
        }
        else{
            //lock offer
            // caller cannot initiate their offer when the system is paused
            require(!paused, "SYSPAUSE");
            //caller cannot push an empty list into an active state
            require(list[myOffers[tx.origin]].length > 0, "NOOFFERS");
            
            //put the offer into the pending offers list
            list[pendingOffers[tradeID]].push(myOffers[tx.origin]);
            activeOffer[tx.origin] = myOffers[tx.origin];
            offerPending[myOffers[tx.origin]] = tradeID;
            offerMap[myOffers[tx.origin]] = tx.origin;

        }
        offerLocked[tx.origin] = !offerLocked[tx.origin];
    }

    function viewActiveOffer() external view returns(uint256[] memory) {
        require(hasAccount[tx.origin], "NOACCT");
        require(activeOffer[tx.origin] != 0, "O!ACTIVE");
        return list[activeOffer[tx.origin]];
    }

    function viewActiveOfferID() external view returns (uint256) {
        require(hasAccount[tx.origin], "NOACCT");
        require(activeOffer[tx.origin] != 0, "O!ACTIVE");
        return activeOffer[tx.origin];
    }

    function offerSubmittedTo() external view returns (uint256) {
        require(activeOffer[tx.origin] != 0, "O!ACTIVE");
        return offerPending[myOffers[tx.origin]];
    }


    /* UTILS */

    function viewAllOpenTrades() external view returns (uint256[] memory) {
        return list[openTrades];
    }
    
    function totalPendingOffersOnTrade(uint256 tradeID) external view returns (uint256) {
        require(activeTrade[tradeMap[tradeID]] != 0, "T!ACTIVE");
        uint myPublishedTradeID = myTrades[tradeMap[tradeID]];
        uint listID = pendingOffers[myPublishedTradeID];
        return list[listID].length;
    }

    function viewList(uint256 listID) external view nZ(listID) returns (uint256[] memory) {
        return list[listID];
    }


    /* ERC721Receiver */

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external override returns (bytes4){
        emit TokenTransferred(operator, from, tokenId, data);
        return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    }


    /* Modifiers */

    modifier nZ(uint256 val) {
        require(val > 0, "ZERO");
        _;
    }
}