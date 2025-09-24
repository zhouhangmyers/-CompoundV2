// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./interface/ComptrollerInterface.sol";
import "./storage/ComptrollerStorage.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "../Utils/computer/ExponentialNoError.sol";
import "../Governance/Comp.sol";

contract Comptroller is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ComptrollerV7Storage,
    ComptrollerInterface,
    ExponentialNoError
{
    /// @notice 当管理员支持一个市场时触发
    event MarketListed(CToken cToken);

    /// @notice 当账户进入一个市场时触发
    event MarketEntered(CToken cToken, address account);

    /// @notice 当账户退出一个市场时触发
    event MarketExited(CToken cToken, address account);

    /// @notice 当管理员更改清算因子时触发
    event NewCloseFactor(uint256 oldCloseFactorMantissa, uint256 newCloseFactorMantissa);

    /// @notice 当管理员更改抵押因子时触发
    event NewCollateralFactor(CToken cToken, uint256 oldCollateralFactorMantissa, uint256 newCollateralFactorMantissa);

    /// @notice 当管理员更改清算奖励时触发
    event NewLiquidationIncentive(uint256 oldLiquidationIncentiveMantissa, uint256 newLiquidationIncentiveMantissa);

    /// @notice 当价格预言机发生变化时触发
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice 当暂停守护者发生变化时触发
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice 当全局暂停某个操作时触发
    event ActionPaused(string action, bool pauseState);

    /// @notice 当特定市场暂停某个操作时触发
    event ActionPaused(CToken cToken, string action, bool pauseState);

    /// @notice 当为市场计算新的借款方COMP速度时触发
    event CompBorrowSpeedUpdated(CToken indexed cToken, uint256 newSpeed);

    /// @notice 当为市场计算新的供应方COMP速度时触发
    event CompSupplySpeedUpdated(CToken indexed cToken, uint256 newSpeed);

    /// @notice 当为贡献者设置新的COMP速度时触发
    event ContributorCompSpeedUpdated(address indexed contributor, uint256 newSpeed);

    /// @notice 当向供应商分发COMP时触发
    event DistributedSupplierComp(
        CToken indexed cToken, address indexed supplier, uint256 compDelta, uint256 compSupplyIndex
    );

    /// @notice 当向借款人分发COMP时触发
    event DistributedBorrowerComp(
        CToken indexed cToken, address indexed borrower, uint256 compDelta, uint256 compBorrowIndex
    );

    /// @notice 当cToken的借贷上限发生变化时触发
    event NewBorrowCap(CToken indexed cToken, uint256 newBorrowCap);

    /// @notice 当借贷上限守护者发生变化时触发
    event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);

    /// @notice 当管理员授予COMP时触发
    event CompGranted(address recipient, uint256 amount);

    /// @notice 当用户累积的COMP被手动调整时触发
    event CompAccruedAdjusted(address indexed user, uint256 oldCompAccrued, uint256 newCompAccrued);

    /// @notice 当用户的COMP应收款项被更新时触发
    event CompReceivableUpdated(address indexed user, uint256 oldCompReceivable, uint256 newCompReceivable);

    /// @notice 市场的初始COMP指数
    uint224 public constant compInitialIndex = 1e36;

    // closeFactorMantissa必须严格大于此值
    uint256 internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa不得超过此值
    uint256 internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // 没有collateralFactorMantissa可以超过此值
    uint256 internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    /**
     * Error
     */
    error Comptroller__AlreadyInMarket(address account, address cToken);
    error Comptroller__HasBorrowBalance(address cToken, uint256 borrowBalance);
    error Comptroller__NotInMarket(address account, address cToken);
    error Comptroller__CTokenNotInList(address cToken);
    error Comptroller__HasIncorrectLiquidity();
    error Comptroller__NoPrice();

    constructor() {
        _disableInitializers();
    }

    function initialize(Comp _comp) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        setCompAddress(_comp);
    }

    ///////////////////////////////////////////////////////////////
    ///////////////////// 市场进入和退出模块 ////////////////////////
    ///////////////////////////////////////////////////////////////

    /**
     * @notice 返回账户已进入的资产
     * @param account 要查询资产的账户地址
     * @return 包含账户已进入资产的动态列表
     */
    function getAssetsIn(address account) external view returns (CToken[] memory) {
        CToken[] memory assets = accountAssets[account];
        return assets;
    }

    /**
     * @notice 检查账户是否已进入特定市场
     * @param account 要检查的账户地址
     * @param cToken 要检查的市场（cToken地址）
     * @return 如果账户已进入市场则返回true，否则返回false
     */
    function checkMembership(address account, CToken cToken) external view returns (bool) {
        return markets[address(cToken)].accountMembership[account];
    }

    /**
     * @notice 添加要包含在账户流动性计算中的资产
     * @param cTokens 要启用的cToken市场地址列表
     */
    function enterMarkets(address[] calldata cTokens) external override {
        uint256 len = cTokens.length;
        for (uint256 i = 0; i < len; i++) {
            CToken cToken = CToken(cTokens[i]);
            addToMarketInternal(cToken, msg.sender);
        }
    }

    /**
     * @notice 将市场添加到借款人的“所在资产”以用于流动性计算
     * @param cToken 要进入的市场
     * @param borrower 要修改的账户地址
     */
    function addToMarketInternal(CToken cToken, address borrower) internal {
        Market storage marketToJoin = markets[address(cToken)];

        require(marketToJoin.isListed, "market is not listed");

        if (marketToJoin.accountMembership[borrower] == true) {
            revert Comptroller__AlreadyInMarket(msg.sender, address(cToken));
        }

        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(cToken);

        emit MarketEntered(cToken, borrower);
    }

    /**
     * @notice 从发送者的账户流动性计算中移除资产
     * @dev 发送者在该资产中不得有未偿还的借贷余额，
     *  或不得为未偿还的借贷提供必要的抵押品。
     * @param cTokenAddress 要移除的资产地址
     */
    function exitMarket(address cTokenAddress) external override {
        CToken cToken = CToken(cTokenAddress);
        /* 从cToken 获取发送者持有的代币和欠款的底层资产 */
        (bool result, uint256 tokensHeld, uint256 amountOwed,) = cToken.getAccountSnapshot(msg.sender);
        require(result, "exitMarket: getAccountSnapshot failed");

        /* 发送者在该市场中不得有未偿还的借款 */
        if (amountOwed != 0) {
            revert Comptroller__HasBorrowBalance(address(cToken), amountOwed);
        }

        /* 如果发送者不被允许赎回所有代币，则拒绝退出市场 */
        redeemAllowedInternal(cTokenAddress, msg.sender, tokensHeld);

        Market storage marketToExit = markets[address(cToken)];

        /* 如果发送者未进入市场，则revert */
        if (!marketToExit.accountMembership[msg.sender]) {
            revert Comptroller__NotInMarket(msg.sender, address(cToken));
        }
        /* 将发送者的市场成员资格标记为false */
        delete marketToExit.accountMembership[msg.sender];

        /* 将CToken从发送者的“所在资产”中移除 */
        CToken[] storage userAssetList = accountAssets[msg.sender];
        uint256 len = userAssetList.length;
        uint256 assetIndex = len;
        for (uint256 i = 0; i < len; i++) {
            if (userAssetList[i] == cToken) {
                assetIndex = i;
                break;
            }
        }

        if (assetIndex == len) {
            revert Comptroller__CTokenNotInList(address(cToken));
        }
        CToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        emit MarketExited(cToken, msg.sender);
    }

    ///////////////////////////////////////////////////////////////
    ///////////////////// 操作许可控制模块 ///////////////////////////
    ///////////////////////////////////////////////////////////////

    /**
     * @notice 检查账户是否应被允许在给定市场铸造代币
     * @param cToken 用于验证铸造的市场
     * @param minter 将获得铸造代币的账户
     * @param mintAmount 供应到市场以换取代币的底层数量
     */
    function mintAllowed(address cToken, address minter, uint256 mintAmount) external override {
        // 暂停是非常严重的情况 - 我们要触发警报
        require(!_mintGuardianPaused, "mint is paused");
        // 避免编译器警告
        minter;
        mintAmount;

        if (!markets[cToken].isListed) {
            revert Comptroller__CTokenNotInList(cToken);
        }

        //保持飞轮运转
        updateCompSupplyIndex(cToken);
        distributeSupplierComp(cToken, minter);
    }

    // 预留钩子
    function mintVerify(address cToken, address minter, uint256 actualMintAmount, uint256 mintTokens)
        external
        virtual
        override
    {}

    /**
     * @notice 检查账户是否应被允许在给定市场赎回代币
     * @param cToken 用于验证赎回的市场
     * @param redeemer 将赎回代币的账户
     * @param redeemTokens 要交换为市场底层资产的cToken数量
     */
    function redeemAllowed(address cToken, address redeemer, uint256 redeemTokens) external override {
        redeemAllowedInternal(cToken, redeemer, redeemTokens);

        // 保持飞轮运转
        updateCompSupplyIndex(cToken);
        distributeSupplierComp(cToken, redeemer);
    }

    function redeemAllowedInternal(address cToken, address redeemer, uint256 redeemTokens) internal view {
        if (!markets[cToken].isListed) {
            revert Comptroller__CTokenNotInList(cToken);
        }

        if (!markets[cToken].accountMembership[redeemer]) {
            revert Comptroller__NotInMarket(redeemer, cToken);
        }

        // 执行假设性流动性检查以防止缺口
        (bool results,, uint256 shortfall) =
            getHypotheticalAccountLiquidityInternal(redeemer, CToken(cToken), redeemTokens, 0);
        if (!results) {
            revert Comptroller__HasIncorrectLiquidity();
        }

        if (shortfall > 0) {
            revert Comptroller__HasIncorrectLiquidity();
        }
    }

    // 预留钩子
    function redeemVerify(address cToken, address redeemer, uint256 redeemAmount, uint256 redeemTokens)
        external
        virtual
        override
    {}

    /**
     * @notice 检查账户是否应被允许借用给定市场的底层资产
     * @param cToken 用于验证借贷的市场
     * @param borrower 将借用资产的账户
     * @param borrowAmount 账户将借用的底层数量
     */
    function borrowAllowed(address cToken, address borrower, uint256 borrowAmount) external override {
        require(!_borrowGuardianPaused, "borrow is paused");

        if (!markets[cToken].isListed) {
            revert Comptroller__CTokenNotInList(cToken);
        }

        if (!markets[cToken].accountMembership[borrower]) {
            // only cTokens may call borrowAllowed if borrower not in market
            require(msg.sender == cToken, "sender must be cToken");
            // attempt to add borrower to the market
            addToMarketInternal(CToken(msg.sender), borrower);
        }

        if (oracle.getUnderlyingPrice(CToken(cToken)) == 0) {
            revert Comptroller__NoPrice();
        }

        uint256 borrowCap = borrowCaps[cToken];
        // 借贷上限0对应无限借贷
        if (borrowCap != 0) {
            uint256 totalBorrows = CToken(cToken).totalBorrows();
            uint256 nextTotalBorrows = totalBorrows + borrowAmount;
            require(nextTotalBorrows <= borrowCap, "market borrow cap reached");
        }

        (bool results,, uint256 shortfall) =
            getHypotheticalAccountLiquidityInternal(borrower, CToken(cToken), 0, borrowAmount);
        if (!results) {
            revert Comptroller__HasIncorrectLiquidity();
        }

        if (shortfall > 0) {
            revert Comptroller__HasIncorrectLiquidity();
        }

        //使用Exp结构体，是因为线性继承是结构体不占用slot，不会使ComptrollerVxStorage的slot错位/冲突
        Exp memory borrowIndex = Exp({mantissa: CToken(cToken).borrowIndex()});
        // 保持飞轮运转
        updateCompBorrowIndex(cToken, borrowIndex);
        distributeBorrowerComp(cToken, borrower, borrowIndex);
    }

    // 预留钩子
    function borrowVerify(address cToken, address borrower, uint256 borrowAmount) external virtual override {}

    /**
     * @notice 检查账户是否应被允许在给定市场偿还借贷
     * @param cToken 用于验证偿还的市场
     * @param payer 将偿还资产的账户
     * @param borrower 借用了资产的账户
     * @param repayAmount 账户将偿还的底层资产数量
     */
    function repayBorrowAllowed(address cToken, address payer, address borrower, uint256 repayAmount)
        external
        override
    {
        payer;
        borrower;
        repayAmount;

        if (!markets[cToken].isListed) {
            revert Comptroller__CTokenNotInList(cToken);
        }

        // 保持飞轮运转
        Exp memory borrowIndex = Exp({mantissa: CToken(cToken).borrowIndex()});
        updateCompBorrowIndex(cToken, borrowIndex);
        distributeBorrowerComp(cToken, borrower, borrowIndex);
    }

    // 预留钩子
    function repayBorrowVerify(
        address cToken,
        address payer,
        address borrower,
        uint256 actualRepayAmount,
        uint256 borrowerIndex
    ) external virtual override {}

    /**
     * @notice 检查是否应被允许进行清算
     * @param cTokenBorrowed 借款人借入的资产
     * @param cTokenCollateral 用作抵押品并将被扣押的资产
     * @param liquidator 偿还借贷并扣押抵押品的地址
     * @param borrower 借款人的地址
     * @param repayAmount 正在被偿还的底层数量
     */
    function liquidateBorrowAllowed(
        address cTokenBorrowed,
        address cTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external view override {
        // 嚀 - 目前未使用
        liquidator;

        if (!markets[cTokenBorrowed].isListed || !markets[cTokenCollateral].isListed) {
            revert Comptroller__CTokenNotInList(cTokenBorrowed);
        }

        uint256 borrowBalance = CToken(cTokenBorrowed).borrowBalanceStored(borrower);

        /* 如果市场已废弃，允许清算账户 */
        if (isDeprecated(CToken(cTokenBorrowed))) {
            require(borrowBalance >= repayAmount, "Can not repay more than the total borrow");
        } else {
            /* 借款人必须有缺口才能被清算 */
            (bool results,, uint256 shortfall) = getAccountLiquidityInternal(borrower);
            if (!results) {
                revert Comptroller__HasIncorrectLiquidity();
            }
            if (shortfall == 0) {
                revert Comptroller__HasIncorrectLiquidity();
            }

            //限制单次清算中最多能偿还的债务比例
            uint256 maxClose = mul_ScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
            if (repayAmount > maxClose) {
                revert Comptroller__HasIncorrectLiquidity();
            }
        }
    }

    // 预留钩子
    function liquidateBorrowVerify(
        address cTokenBorrowed,
        address cTokenCollateral,
        address liquidator,
        address borrower,
        uint256 actualRepayAmount,
        uint256 seizeTokens
    ) external override {}

    /**
     * @notice 检查是否应被允许扣押资产
     * @param cTokenCollateral 用作抵押品并将被扣押的资产
     * @param cTokenBorrowed 借款人借入的资产
     * @param liquidator 偿还借贷并扣押抵押品的地址
     * @param borrower 借款人的地址
     * @param seizeTokens 要扣押的抵押代币数量
     */
    function seizeAllowed(
        address cTokenCollateral,
        address cTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external override {
        // 暂停是非常严重的情况 - 我们要触发警报
        require(!seizeGuardianPaused, "seize is paused");

        // 嚀 - 目前未使用
        seizeTokens;

        if (!markets[cTokenCollateral].isListed || !markets[cTokenBorrowed].isListed) {
            revert Comptroller__CTokenNotInList(cTokenCollateral);
        }

        if (CToken(cTokenCollateral).comptroller() != CToken(cTokenBorrowed).comptroller()) {
            revert Comptroller__CTokenNotInList(cTokenCollateral);
        }

        // 保持飞轮运转
        updateCompSupplyIndex(cTokenCollateral);
        distributeSupplierComp(cTokenCollateral, borrower);
        distributeSupplierComp(cTokenCollateral, liquidator);
    }

    // 预留钩子
    function seizeVerify(
        address cTokenCollateral,
        address cTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external override {}

    /**
     * @notice 检查账户是否应被允许在给定市场转移代币
     * @param cToken 用于验证转移的市场
     * @param src 提供代币的账户
     * @param dst 接收代币的账户
     * @param transferTokens 要转移的cToken数量
     */
    function transferAllowed(address cToken, address src, address dst, uint256 transferTokens) external override {
        // 暂停是非常严重的情况 - 我们要触发警报
        require(!transferGuardianPaused, "transfer is paused");

        // 目前唯一的考虑是
        //  src是否被允许赎回这么多代币
        redeemAllowedInternal(cToken, src, transferTokens);

        // 保持飞轮运转
        updateCompSupplyIndex(cToken);
        distributeSupplierComp(cToken, src);
        distributeSupplierComp(cToken, dst);
    }

    // 预留钩子
    function transferVerify(address cToken, address src, address dst, uint256 transferTokens) external override {}

    //////////////////////////////////////////////////////////////////////////////////
    ////////////////////// 流动性计算和清算价格模块 //////////////////////////////////////
    //////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev 避免在计算账户流动性时堆栈深度限制的局部变量。
     *  注意`cTokenBalance`是账户在市场中拥有的cToken数量，
     *  而`borrowBalance`是账户借用的底层数量。
     */
    struct AccountLiquidityLocalVars {
        uint256 sumCollateral;
        uint256 sumBorrowPlusEffects;
        uint256 cTokenBalance;
        uint256 borrowBalance;
        uint256 exchangeRateMantissa;
        uint256 oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice 确定当前账户相对于抵押品要求的流动性
     * @return (可能的错误代码（半透明），
     *             账户超过抵押品要求的流动性，
     *          账户低于抵押品要求的缺口）
     */
    function getAccountLiquidity(address account) public view returns (bool, uint256, uint256) {
        (bool result, uint256 liquidity, uint256 shortfall) =
            getHypotheticalAccountLiquidityInternal(account, CToken(address(0)), 0, 0);

        return (result, liquidity, shortfall);
    }

    /**
     * @notice 确定当前账户相对于抵押品要求的流动性
     * @return (可能的错误代码，
     *             账户超过抵押品要求的流动性，
     *          账户低于抵押品要求的缺口）
     */
    function getAccountLiquidityInternal(address account) internal view returns (bool, uint256, uint256) {
        return getHypotheticalAccountLiquidityInternal(account, CToken(address(0)), 0, 0);
    }

    /**
     * @notice 确定如果给定数量被赎回/借入，账户流动性将是多少
     * @param cTokenModify 假设性赎回/借入的市场
     * @param account 要确定流动性的账户
     * @param redeemTokens 假设性赎回的代币数量
     * @param borrowAmount 假设性借入的底层数量
     * @return (可能的错误代码（半透明），
     *             假设性账户超过抵押品要求的流动性，
     *          假设性账户低于抵押品要求的缺口）
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address cTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) public view returns (bool, uint256, uint256) {
        (bool result, uint256 liquidity, uint256 shortfall) =
            getHypotheticalAccountLiquidityInternal(account, CToken(cTokenModify), redeemTokens, borrowAmount);
        return (result, liquidity, shortfall);
    }

    /**
     * @notice 确定如果给定数量被赎回/借入，账户流动性将是多少
     * @param cTokenModify 假设性赎回/借入的市场
     * @param account 要确定流动性的账户
     * @param redeemTokens 假设性赎回的代币数量
     * @param borrowAmount 假设性借入的底层数量
     * @dev 注意，我们使用存储的数据计算每个抵押品cToken的exchangeRateStored，
     *  而不计算累积利息。
     * @return (可能的错误代码，
     *             假设性账户超过抵押品要求的流动性，
     *          假设性账户低于抵押品要求的缺口）
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        CToken cTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) internal view returns (bool, uint256, uint256) {
        AccountLiquidityLocalVars memory vars; // 保存所有计算结果
        bool result;

        //1.遍历用户所有资产
        CToken[] memory assets = accountAssets[account];
        for (uint256 i = 0; i < assets.length; i++) {
            CToken asset = assets[i];

            //2.计算每个资产的价值

            // 获取用户在该资产的余额和借款
            (result, vars.cTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) =
                asset.getAccountSnapshot(account);
            if (!result) {
                return (false, 0, 0);
            }

            //获取当前资产的抵押因子
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});

            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (false, 0, 0);
            }
            // 获取当前资产的价值
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // 获取CToken的汇率
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // 计算抵押品的有效价值
            vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

            // 累加进总抵押价值记录中
            vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.cTokenBalance, vars.sumCollateral);

            // 计算总借款价值
            vars.sumBorrowPlusEffects =
                mul_ScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

            //4. 模拟假设操作的影响
            if (asset == cTokenModify) {
                // 赎回效应
                // 减少抵押品价值

                // 不是这样做：sumCollateral -= tokensToDenom * redeemTokens
                // 而是这样做：vars.sumBorrowPlusEffects += tokensToDenom * redeemTokens
                // 人话就是：赎回的这部分价值，我给他累加起来，当作借款，最后判断总抵押是否大于总借款。
                vars.sumBorrowPlusEffects =
                    mul_ScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);

                // 借贷效应
                // 增加借款价值
                // 这里就比较好理解了，因为是借款，直接累加到总借款中，最后判断总抵押是否大于总借款即可。
                vars.sumBorrowPlusEffects =
                    mul_ScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
            }
        }

        // 这些是安全的，因为首先检查了下溢条件
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            //      1.是否成功，2.抵押品剩余总价值，3.负债总价值
            return (true, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (true, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    /**
     * @notice 根据给定的底层数量计算要扣押的抵押品资产代币数量
     * @dev 用于清算（在cToken.liquidateBorrowFresh中调用）
     * @param cTokenBorrowed 借入的cToken地址
     * @param cTokenCollateral 抵押品cToken地址
     * @param actualRepayAmount 要转换为cTokenCollateral代币的cTokenBorrowed底层数量
     * @return (错误代码, 在清算中要扣押的cTokenCollateral代币数量)
     */
    function liquidateCalculateSeizeTokens(address cTokenBorrowed, address cTokenCollateral, uint256 actualRepayAmount)
        external
        view
        override
        returns (bool, uint256)
    {
        /* 读取借入市场和抵押市场的预言机价格 */
        uint256 priceBorrowedMantissa = oracle.getUnderlyingPrice(CToken(cTokenBorrowed));
        uint256 priceCollateralMantissa = oracle.getUnderlyingPrice(CToken(cTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (false, 0);
        }

        /*
         * 获取汇率并计算要扣押的抵押代币数量：
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint256 exchangeRateMantissa = CToken(cTokenCollateral).exchangeRateStored(); // 注意：错误时回滚
        uint256 seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(Exp({mantissa: liquidationIncentiveMantissa}), Exp({mantissa: priceBorrowedMantissa}));
        denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);
        //   核心计算公式

        //   seizeTokens = actualRepayAmount * liquidationIncentive * priceBorrowed / (priceCollateral * exchangeRate)
        /**
         *  更直观的理解
         *
         *         1. actualRepayAmount * liquidationIncentive = 清算人应得的总价值（含奖励）
         *         2. priceBorrowed / priceCollateral = 汇率换算，1单位抵押品值多少单位借款
         *         3. / exchangeRate = 底层资产转换为cToken数量
         *
         *          本质上就是：清算人用借款资产偿还债务，按照价格比例（含奖励）获得等价的抵押品cToken。
         */
        return (true, seizeTokens);
    }

    /////////////////////////////////////////////////////////////////////////////////
    /////////////////////// 管理员函数 //////////////////////////////////////
    /////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice 为comptroller设置新的价格预言机
     * @dev 管理员函数，用于设置新的价格预言机
     * @param newOracle 新的价格预言机合约地址
     */
    function _setPriceOracle(PriceOracle newOracle) public onlyOwner {
        // 跟踪comptroller的旧预言机
        PriceOracle oldOracle = oracle;

        // 将comptroller的预言机设置为newOracle
        oracle = newOracle;

        // 发出 NewPriceOracle(oldOracle, newOracle) 事件
        emit NewPriceOracle(oldOracle, newOracle);
    }

    /**
     * @notice 设置清算借贷时使用的closeFactor
     * @dev 管理员函数，用于设置closeFactor
     * @param newCloseFactorMantissa 新的关闭因子，按 1e18 缩放
     */
    function _setCloseFactor(uint256 newCloseFactorMantissa) external onlyOwner {
        uint256 oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);
    }

    /**
     * @notice 为市场设置抵押因子
     * @dev 管理员函数，用于设置每个市场的抵押因子
     * @param cToken 要设置因子的市场
     * @param newCollateralFactorMantissa 新的抵押因子，按 1e18 缩放
     */
    function _setCollateralFactor(CToken cToken, uint256 newCollateralFactorMantissa) external onlyOwner {
        // 验证市场是否被列出
        Market storage market = markets[address(cToken)];
        if (!market.isListed) {
            revert Comptroller__CTokenNotInList(address(cToken));
        }

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        // 检查抵押因子 <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            revert Comptroller__HasIncorrectLiquidity();
        }

        // 如果抵押因子 != 0，价格 == 0 则失败
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(cToken) == 0) {
            revert Comptroller__NoPrice();
        }

        // 将市场的抵押因子设置为新的抵押因子，记住旧值
        uint256 oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // 发出包含资产、旧抵押因子和新抵押因子的事件
        emit NewCollateralFactor(cToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);
    }

    /**
     * @notice 设置清算奖励
     * @dev 管理员函数，用于设置清算奖励
     * @param newLiquidationIncentiveMantissa 新的清算奖励，按 1e18 缩放
     */
    function _setLiquidationIncentive(uint256 newLiquidationIncentiveMantissa) external onlyOwner {
        // 检查调用者是否为管理员

        // 保存当前值以供日志使用
        uint256 oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // 将清算奖励设置为新的奖励
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // 发出包含旧奖励和新奖励的事件
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);
    }

    /**
     * @notice 将市场添加到市场映射中并设置为已列出
     * @dev 管理员函数，用于设置isListed并添加对市场的支持
     * @param cToken 要列出的市场（代币）地址
     */
    function _supportMarket(CToken cToken) external onlyOwner {
        if (markets[address(cToken)].isListed) {
            revert Comptroller__CTokenNotInList(address(cToken));
        }

        cToken.isCToken(); // 健全性检查以确保它真的是CToken

        // 注意 isComped 已不再活跃使用
        Market storage newMarket = markets[address(cToken)];
        newMarket.isListed = true;
        newMarket.isComped = false;
        newMarket.collateralFactorMantissa = 0;

        _addMarketInternal(address(cToken));
        _initializeMarket(address(cToken));

        emit MarketListed(cToken);
    }

    function _addMarketInternal(address cToken) internal {
        for (uint256 i = 0; i < allMarkets.length; i++) {
            require(allMarkets[i] != CToken(cToken), "market already added");
        }
        allMarkets.push(CToken(cToken));
    }

    function _initializeMarket(address cToken) internal {
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");

        CompMarketState storage supplyState = compSupplyState[cToken];
        CompMarketState storage borrowState = compBorrowState[cToken];

        /*
         * 更新市场状态指数
         */
        if (supplyState.index == 0) {
            // 用默认值初始化供应状态指数
            supplyState.index = compInitialIndex;
        }

        if (borrowState.index == 0) {
            // 用默认值初始化借款状态指数
            borrowState.index = compInitialIndex;
        }

        /*
         * 更新市场状态区块号
         */
        supplyState.block = borrowState.block = blockNumber;
    }

    /**
     * @notice 为给定的cToken市场设置给定的借贷上限。使总借贷达到或超过借贷上限的借贷将回滚。
     * @dev 管理员或borrowCapGuardian函数，用于设置借贷上限。借贷上限为0对应无限制借贷。
     * @param cTokens 要更改借贷上限的市场（代币）地址
     * @param newBorrowCaps 要设置的新借贷上限值（底层资产）。值为0对应无限制借贷。
     */
    function _setMarketBorrowCaps(CToken[] calldata cTokens, uint256[] calldata newBorrowCaps) external onlyOwner {
        uint256 numMarkets = cTokens.length;
        uint256 numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for (uint256 i = 0; i < numMarkets; i++) {
            borrowCaps[address(cTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(cTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice 管理员函数，用于更改借贷上限守护者
     * @param newBorrowCapGuardian 新借贷上限守护者的地址
     */
    function _setBorrowCapGuardian(address newBorrowCapGuardian) external onlyOwner {
        // 保存当前值以包含在日志中
        address oldBorrowCapGuardian = borrowCapGuardian;

        // Store borrowCapGuardian with value newBorrowCapGuardian
        borrowCapGuardian = newBorrowCapGuardian;

        // Emit NewBorrowCapGuardian(OldBorrowCapGuardian, NewBorrowCapGuardian)
        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    /**
     * @notice 管理员函数，用于更改暂停守护者
     * @param newPauseGuardian 新暂停守护者的地址
     */
    function _setPauseGuardian(address newPauseGuardian) public onlyOwner {
        // 保存当前值以包含在日志中
        address oldPauseGuardian = pauseGuardian;

        // 将pauseGuardian存储为newPauseGuardian值
        pauseGuardian = newPauseGuardian;

        // 发出NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)事件
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);
    }

    function _setMintPaused(CToken cToken, bool state) public returns (bool) {
        require(markets[address(cToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == owner(), "only pause guardian and admin can pause");
        require(msg.sender == owner() || state == true, "only admin can unpause");

        mintGuardianPaused[address(cToken)] = state;
        emit ActionPaused(cToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(CToken cToken, bool state) public returns (bool) {
        require(markets[address(cToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == owner(), "only pause guardian and admin can pause");
        require(msg.sender == owner() || state == true, "only admin can unpause");

        borrowGuardianPaused[address(cToken)] = state;
        emit ActionPaused(cToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == owner(), "only pause guardian and admin can pause");
        require(msg.sender == owner() || state == true, "only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == owner(), "only pause guardian and admin can pause");
        require(msg.sender == owner() || state == true, "only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    /////////////////////////////////////////////////////////////////////////
    ////////////////////////COMP分发模块/////////////////////////////////
    /////////////////////////////////////////////////////////////////////////

    /**
     * @notice 为单个市场设置COMP速度
     * @param cToken 要更新COMP速度的市场
     * @param supplySpeed 市场的新供应方COMP速度
     * @param borrowSpeed 市场的新借贷方COMP速度
     */
    function setCompSpeedInternal(CToken cToken, uint256 supplySpeed, uint256 borrowSpeed) internal {
        Market storage market = markets[address(cToken)];
        require(market.isListed, "comp market is not listed");

        if (compSupplySpeeds[address(cToken)] != supplySpeed) {
            // Supply speed updated so let's update supply state to ensure that
            //  1. COMP accrued properly for the old speed, and
            //  2. COMP accrued at the new speed starts after this block.
            updateCompSupplyIndex(address(cToken));

            // Update speed and emit event
            compSupplySpeeds[address(cToken)] = supplySpeed;
            emit CompSupplySpeedUpdated(cToken, supplySpeed);
        }

        if (compBorrowSpeeds[address(cToken)] != borrowSpeed) {
            // Borrow speed updated so let's update borrow state to ensure that
            //  1. COMP accrued properly for the old speed, and
            //  2. COMP accrued at the new speed starts after this block.
            Exp memory borrowIndex = Exp({mantissa: cToken.borrowIndex()});
            updateCompBorrowIndex(address(cToken), borrowIndex);

            // Update speed and emit event
            compBorrowSpeeds[address(cToken)] = borrowSpeed;
            emit CompBorrowSpeedUpdated(cToken, borrowSpeed);
        }
    }

    /**
     * @notice 通过更新供应指数向市场累积COMP
     * @param cToken 要更新供应指数的市场
     * @dev 指数是累积的每个cToken的COMP总和。
     */
    function updateCompSupplyIndex(address cToken) internal {
        CompMarketState storage supplyState = compSupplyState[cToken];
        uint256 supplySpeed = compSupplySpeeds[cToken];
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");
        uint256 deltaBlocks = sub_(uint256(blockNumber), uint256(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint256 supplyTokens = CToken(cToken).totalSupply();
            uint256 compAccrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(compAccrued, supplyTokens) : Double({mantissa: 0});
            supplyState.index =
                safe224(add_(Double({mantissa: supplyState.index}), ratio).mantissa, "new index exceeds 224 bits");
            supplyState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            supplyState.block = blockNumber;
        }
    }

    /**
     * @notice 通过更新借贷指数向市场累积COMP
     * @param cToken 要更新借贷指数的市场
     * @dev 指数是累积的每个cToken的COMP总和。
     */
    function updateCompBorrowIndex(address cToken, Exp memory marketBorrowIndex) internal {
        CompMarketState storage borrowState = compBorrowState[cToken];
        uint256 borrowSpeed = compBorrowSpeeds[cToken];
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");
        uint256 deltaBlocks = sub_(uint256(blockNumber), uint256(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint256 borrowAmount = div_(CToken(cToken).totalBorrows(), marketBorrowIndex);
            uint256 compAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(compAccrued, borrowAmount) : Double({mantissa: 0});
            borrowState.index =
                safe224(add_(Double({mantissa: borrowState.index}), ratio).mantissa, "new index exceeds 224 bits");
            borrowState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            borrowState.block = blockNumber;
        }
    }

    /**
     * @notice 计算供应商累积的COMP并可能将其转移给他们
     * @param cToken 供应商正在交互的市场
     * @param supplier 要分发COMP的供应商地址
     */
    function distributeSupplierComp(address cToken, address supplier) internal {
        // TODO：如果用户不在供应商市场中，则不分发供应商COMP。
        // 这个检查应该尽可能高效地使用燃料，因为distributeSupplierComp在很多地方被调用。
        // - 我们真的不想调用外部合约，因为这非常昂贵。

        CompMarketState storage supplyState = compSupplyState[cToken];
        uint256 supplyIndex = supplyState.index;
        uint256 supplierIndex = compSupplierIndex[cToken][supplier];

        // 将供应商的指数更新为当前指数，因为我们正在分发累积的COMP
        compSupplierIndex[cToken][supplier] = supplyIndex;

        if (supplierIndex == 0 && supplyIndex >= compInitialIndex) {
            // 处理用户在设置市场供应状态指数之前就供应代币的情况。
            // 从供应商奖励首次为该市场设置时开始，奖励用户累积的COMP。
            supplierIndex = compInitialIndex;
        }

        // 计算每个cToken累积COMP的累积和变化
        Double memory deltaIndex = Double({mantissa: sub_(supplyIndex, supplierIndex)});

        uint256 supplierTokens = CToken(cToken).balanceOf(supplier);

        // 计算累积COMP：cTokenAmount * accruedPerCToken
        uint256 supplierDelta = mul_(supplierTokens, deltaIndex);

        uint256 supplierAccrued = add_(compAccrued[supplier], supplierDelta);
        compAccrued[supplier] = supplierAccrued;

        emit DistributedSupplierComp(CToken(cToken), supplier, supplierDelta, supplyIndex);
    }

    /**
     * @notice 计算借款人累积的COMP并可能将其转移给他们
     * @dev 借款人在与协议首次交互后才会开始累积。
     * @param cToken 借款人正在交互的市场
     * @param borrower 要分发COMP的借款人地址
     */
    function distributeBorrowerComp(address cToken, address borrower, Exp memory marketBorrowIndex) internal {
        // TODO：如果用户不在借款人市场中，则不分发供应商COMP。
        // 这个检查应该尽可能高效地使用燃料，因为distributeBorrowerComp在很多地方被调用。
        // - 我们真的不想调用外部合约，因为这非常昂贵。

        CompMarketState storage borrowState = compBorrowState[cToken];
        uint256 borrowIndex = borrowState.index;
        uint256 borrowerIndex = compBorrowerIndex[cToken][borrower];

        // 将借款人的指数更新为当前指数，因为我们正在分发累积的COMP
        compBorrowerIndex[cToken][borrower] = borrowIndex;

        if (borrowerIndex == 0 && borrowIndex >= compInitialIndex) {
            // 处理用户在设置市场借贷状态指数之前就借入代币的情况。
            // 从借款人奖励首次为该市场设置时开始，奖励用户累积的COMP。
            borrowerIndex = compInitialIndex;
        }

        // 计算每个借入单位累积COMP的累积和变化
        Double memory deltaIndex = Double({mantissa: sub_(borrowIndex, borrowerIndex)});

        uint256 borrowerAmount = div_(CToken(cToken).borrowBalanceStored(borrower), marketBorrowIndex);

        // 计算累积COMP：cTokenAmount * accruedPerBorrowedUnit
        uint256 borrowerDelta = mul_(borrowerAmount, deltaIndex);

        uint256 borrowerAccrued = add_(compAccrued[borrower], borrowerDelta);
        compAccrued[borrower] = borrowerAccrued;

        emit DistributedBorrowerComp(CToken(cToken), borrower, borrowerDelta, borrowIndex);
    }

    /**
     * @notice 计算贡献者自上次累积以来的额外累积COMP
     * @param contributor 要计算贡献者奖励的地址
     */
    function updateContributorRewards(address contributor) public {
        uint256 compSpeed = compContributorSpeeds[contributor];
        uint256 blockNumber = getBlockNumber();
        uint256 deltaBlocks = sub_(blockNumber, lastContributorBlock[contributor]);
        if (deltaBlocks > 0 && compSpeed > 0) {
            uint256 newAccrued = mul_(deltaBlocks, compSpeed);
            uint256 contributorAccrued = add_(compAccrued[contributor], newAccrued);

            compAccrued[contributor] = contributorAccrued;
            lastContributorBlock[contributor] = blockNumber;
        }
    }

    /**
     * @notice 领取持有者在所有市场累积的所有comp
     * @param holder 要领取COMP的地址
     */
    function claimComp(address holder) public {
        return claimComp(holder, allMarkets);
    }

    /**
     * @notice 领取持有者在指定市场累积的所有comp
     * @param holder 要领取COMP的地址
     * @param cTokens 要领取COMP的市场列表
     */
    function claimComp(address holder, CToken[] memory cTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimComp(holders, cTokens, true, true);
    }

    /**
     * @notice 领取持有者们累积的所有comp
     * @param holders 要领取COMP的地址
     * @param cTokens 要领取COMP的市场列表
     * @param borrowers 是否领取通过借贷赚取的COMP
     * @param suppliers 是否领取通过供应赚取的COMP
     */
    function claimComp(address[] memory holders, CToken[] memory cTokens, bool borrowers, bool suppliers) public {
        for (uint256 i = 0; i < cTokens.length; i++) {
            CToken cToken = cTokens[i];
            require(markets[address(cToken)].isListed, "market must be listed");
            if (borrowers == true) {
                Exp memory borrowIndex = Exp({mantissa: cToken.borrowIndex()});
                updateCompBorrowIndex(address(cToken), borrowIndex);
                for (uint256 j = 0; j < holders.length; j++) {
                    distributeBorrowerComp(address(cToken), holders[j], borrowIndex);
                }
            }
            if (suppliers == true) {
                updateCompSupplyIndex(address(cToken));
                for (uint256 j = 0; j < holders.length; j++) {
                    distributeSupplierComp(address(cToken), holders[j]);
                }
            }
        }
        for (uint256 j = 0; j < holders.length; j++) {
            compAccrued[holders[j]] = grantCompInternal(holders[j], compAccrued[holders[j]]);
        }
    }

    /**
     * @notice 向用户转移COMP
     * @dev 注意：如果COMP不足，我们不会执行转移。
     * @param user 要转移COMP的用户地址
     * @param amount 要（可能）转移的COMP数量
     * @return 未转移给用户的COMP数量
     */
    function grantCompInternal(address user, uint256 amount) internal returns (uint256) {
        Comp comp = Comp(getCompAddress());
        uint256 compRemaining = comp.balanceOf(address(this));
        if (amount > 0 && amount <= compRemaining) {
            comp.transfer(user, amount);
            return 0;
        }
        return amount;
    }
    /**
     * COMP分发管理 **
     */

    /**
     * @notice 向接收者转移COMP
     * @dev 注意：如果COMP不足，我们不会执行转移。
     * @param recipient 要转移COMP的接收者地址
     * @param amount 要（可能）转移的COMP数量
     */
    function _grantComp(address recipient, uint256 amount) public onlyOwner {
        uint256 amountLeft = grantCompInternal(recipient, amount);
        require(amountLeft == 0, "insufficient comp for grant");
        emit CompGranted(recipient, amount);
    }

    /**
     * @notice 为指定市场设置COMP借贷和供应速度。
     * @param cTokens 要更新COMP速度的市场。
     * @param supplySpeeds 对应市场的新供应方COMP速度。
     * @param borrowSpeeds 对应市场的新借贷方COMP速度。
     */
    function _setCompSpeeds(CToken[] memory cTokens, uint256[] memory supplySpeeds, uint256[] memory borrowSpeeds)
        public
        onlyOwner
    {
        uint256 numTokens = cTokens.length;
        require(
            numTokens == supplySpeeds.length && numTokens == borrowSpeeds.length,
            "Comptroller::_setCompSpeeds invalid input"
        );

        for (uint256 i = 0; i < numTokens; ++i) {
            setCompSpeedInternal(cTokens[i], supplySpeeds[i], borrowSpeeds[i]);
        }
    }

    /**
     * @notice 为单个贡献者设置COMP速度
     * @param contributor 要更新COMP速度的贡献者
     * @param compSpeed 贡献者的新COMP速度
     */
    function _setContributorCompSpeed(address contributor, uint256 compSpeed) public onlyOwner {
        // 注意，可以将COMP速度设置为0来停止贡献者的流动性奖励
        updateContributorRewards(contributor);
        if (compSpeed == 0) {
            // 释放存储
            delete lastContributorBlock[contributor];
        } else {
            lastContributorBlock[contributor] = getBlockNumber();
        }
        compContributorSpeeds[contributor] = compSpeed;

        emit ContributorCompSpeedUpdated(contributor, compSpeed);
    }

    /**
     * @notice 返回所有市场
     * @dev 可以使用自动getter来访问单个市场。
     * @return 市场地址列表
     */
    function getAllMarkets() public view returns (CToken[] memory) {
        return allMarkets;
    }

    /**
     * @notice 如果给定的cToken市场已被废弃则返回true
     * @dev 废弃cToken市场中的所有借贷可以立即被清算
     * @param cToken 要检查是否废弃的市场
     */
    function isDeprecated(CToken cToken) public view returns (bool) {
        return markets[address(cToken)].collateralFactorMantissa == 0 && borrowGuardianPaused[address(cToken)] == true
            && cToken.reserveFactorMantissa() == 1e18;
    }

    function getBlockNumber() public view virtual returns (uint256) {
        return block.number;
    }

    function getCompAddress() public view returns (address) {
        return address(comp);
    }

    function setCompAddress(Comp _comp) public onlyOwner {
        comp = _comp;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
