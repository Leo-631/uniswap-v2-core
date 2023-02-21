pragma solidity =0.7.6;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    // 最小流动性定义 最小流动性的定义是1000，在后面铸币方法的解析中，用来提供初始流动性时的汽油费
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    // SELECTOR常量值为transfer(address,unit256)字符串哈希值的前4个字节，这个用于直接使用call方法调用token的转账方法。
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    // 工厂地址 因为pair合约是通过工厂合约进行部署的，所有会有一个变量专门存放工厂合约的地址。
    address public factory;
    // token地址 pair合约的含义，就是一对token，所有在合约中会存放两个token的地址，便于调用。
    address public token0;
    address public token1;
    // 储备量是当前pair合约所持有的token数量，blockTimestampLast主要用于判断是不是区块的第一笔交易。
    // ***reserve0、reserve1和blockTimestampLast三者的位数加起来正好是unit的位数。
    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves
    // 价格最后累计，是用于Uniswap v2所提供的价格预言机上，该数值会在每个区块的第一笔交易进行更新。
    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    // kLast这个变量在没有开启收费的时候，是等于0的，只有当开启平台收费的时候，这个值才等于k值，因为一般开启平台收费，
    // 那么k值就不会一直等于两个储备量相乘的结果。
    // 记录某个时刻恒定乘积中积的值，主要用于开发团队手续费计算。
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    // 锁定变量，防止重入
    uint private unlocked = 1;

    // 修饰方法，锁定运行防止重入
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }
    // 返回三个信息，token0的储备量，token1的储备量，blockTimestampLast：上一个区块的时间戳。
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }
    // 私有安全转账方法 该方法实现了只知道token合约地址就可以直接调用transfer方法的功能，具体实现如下，这个方法传入了三个参数，
    // 分别是token：合约的地址，to：要转账的地址，value：要转账的金额。然后直接使用call方法直接调用对应token合约的transfer方法，
    // 获取返回值，需要判断返回值为true并且返回的data长度为0或者解码后为true。
    // 使用call方法的优势在于可以在不知道token合约具体代码的前提下调用其方法。
    // 调用token合约地址的低级transfer方法
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }
    // 铸造事件
    event Mint(address indexed sender, uint amount0, uint amount1);
    // 销毁事件
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    // 交换事件
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    // 同步事件
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        factory = msg.sender;
    }
    // initialze方法是Solidity中一个比较特殊的方法，它仅仅只有在合约创建之后调用一次，
    // 为什么使用initialze方法初始化pair合约而不是在构造函数中初始化，这是因为pair合约是通过create2部署的，
    // create2部署合约的特点就在于部署合约的地址是可预测的，并且后一次部署的合约可以把前一次部署的合约给覆盖，
    // 这样可以实现合约的升级。如果想要实现升级，就需要构造函数不能有任何参数，这样才能让每次部署的地址都保持一致，
    // 具体细节可以查看create2的文档。 在这个initialize方法中，主要是分别赋予两个token的地址。
    // // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }
    // 私有更新储备量方法主要用于每次添加流动性或者减少流动性之后调用，用于将余额同步给储备量。
    // 并且会判断时间流逝，在每一个区块的第一次调用时候，更新价格累加器，用于Uniswap v2的价格预言机。
    // 在方法最开始的时候，会判断余额会不会导致储备量溢出，如果溢出的话，就revert，
    // 这个时候就需要有人从外部调用skim方法，修正溢出，将多出的token转出。
    // 在这个方法里面除了更新reserve0和reserve1之外，还更新了blockTimestampLast为当前区块时间戳。
    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        // 确认余额0和余额1小于等于最大的uint112
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        // 区块时间戳，将时间戳转换成uint32
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        // 计算时间流逝
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        // 如果时间流逝>0，并且储备量0、1不等于0，也就是第一个调用
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // 价格0最后累计 += 储备量1 * 2**112 / 储备量0 * 时间流逝
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            // 价格1最后累计 += 储备量0 * 2**112 / 储备量1 * 时间流逝
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        //将这个区块的时间戳赋值给上一个区块的时间戳
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // 平台手续费收取方法 平台手续费的是否开启的开关是在factory合约中定义的
    // 如果收取平台收费的话，那么收取的金额为交易手续费的1/6,剩下的5/6发给流动性提供者。
    // _mintFee函数首先获取factory合约里面的address(feeTo), 这是平台收取手续费的地址。
    // 然后判断address(feeTo)是否等于address(0)决定是否收取平台手续费。
    // 如果开启平台手续费收取，首先会判断kLast是否为0，如果不为0就进行平台手续费的计算。
    // 如果每次用户交易都计算并发送手续费，无疑会增加gas。所以平台会累计起来，先不发送，直到发生流动性时再一次性发送。
    // 所以平台手续费的计算，首先要明确一点，因为每一笔交易都会有千分之三的手续费，那么k值也会随着缓慢增加，
    // 所有连续两个时刻之间的k值差值就是这段时间的手续费。
    // 参数为池子中的两种币的数值。
    //公式：Sm = ((√k2-√k1)*S1)/(5*(√k2+√k1))。
    // 其中Sm为因流动性铸造给feeTo地址的激励，√k1是之前某个时刻的乘积，√k2为调用接口的参数的乘积，
    // S1是总的ERC20的数量，保存再工厂合约里。5是由于流动性提供者能获得5/6的手续费而通过公式变形产生。
    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        //查看工厂中的收取手续费的地址是否存在
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        //定义k值，累计的手续费
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {   
                // 计算（_reserve0*_reserve1）的平方根
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                // 计算k值的平方根
                uint rootKLast = Math.sqrt(_kLast);
                // 如果rootK>rootKLast
                if (rootK > rootKLast) {
                    // 分子 = erc20总量(可以指uniswapv2的代币总量) * (rootK - rootKLast)
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    // 分母 = rootK * 5 + rootKLast
                    uint denominator = rootK.mul(5).add(rootKLast);
                    // 流动性 = 分子 / 分母
                    uint liquidity = numerator / denominator;
                    // 如果流动性 > 0 将流动性铸造给feeTo地址（发的代币可以理解为uniswapv2的代币）
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        // 否则如果_kLast不等于0
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // mint函数用于在用户提供流动性时（提供一定比例的两种ERC20到交易对）增发流动性代币给提供者。
    // 注意流动性代币也是一种ERC20代币，是可以交易的，函数的参数为接收流动性代币的地址，
    // 返回值为获得的流动性，在uniswap中流动性就表示系统增发的ERC20代币。
    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        // 获取储备量0和储备量1
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // 获取当前合约在token0和token1合约内的余额
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        // amount = 余额 - 储备
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);
        // 返回铸造费开关
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 获取totalSupply
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        // 如果_totalSupply等于0
        if (_totalSupply == 0) {
            // 流动性 = （数量0 * 数量1）的平方根 - 最小流动性1000
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
           // 在总量为0的初始状态，永久锁定最低流动性，即向空地址发送最低流动性MINIMUM_LIQUIDITY后记录日志
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            // 流动性 = 最小值（amount0 * _totalSupply / _reserve0 和 (amount1 * _totalSupply) / reserve1）
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        // 确认流动性 > 0
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        // 铸造流动性给to地址
        _mint(to, liquidity);
        // 更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        // 如果铸造费开关为true,k值 = 储备0 * 储备1，确定K值
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        // 触发铸造事件
        emit Mint(msg.sender, amount0, amount1);
    }
    // burn销毁流动性方法
    // 如果流动性的提供者想要收回流动性，那么就需要调用该方法。
    // 首先通过getReserves()方法获取现在的储备量。
    // 然后获取token0和token1在当前pair合约的余额。
    // 然后从当前合约的balanceOf获取要销毁的流动性金额，这里为什么是从自身获取，
    // 是因为当前合约的余额是流动性提供者通过路由合约发送到pair合约要销毁的金额。
    // 计算平台手续费。
    // 获取totalSupply,然后计算流动性提供者可以取出的token0和token1的数量,数量分别为amount0和amount1。
    // 直接通过如下公式计算得到
    // 实际上，上述公式可以转换成如下公式，取出来token的数量与持有的流动性占总流动性的比例有关，
    // 这样可以将流动性提供者在存入流动性期间所获取的流动性挖矿的收益也取出。
    // 然后确保取出的amount大于0
    // 销毁合约内的流动性数量，发送token给address(to), 更新储备量。
    // 如果有平台手续费收取的话，重新计算k值。
    // 发送销毁代币事件。
    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        // 获取储备量0，储备量1
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // 带入变量
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        // 获取当前合约在token0合约内的余额
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        // 从当前合约的balanceOf映射中获取当前合约自身流动性数量
        // 当前合约的余额是用户通过路由合约发送到pair合约要销毁的金额
        uint liquidity = balanceOf[address(this)];
        // 返回铸造费开关
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 获取totalSupply
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        // amount0和amount1是用户能取出来多少的token0和token1的数额(与流动性有关)
        // amount0 = 流动性数量 * 余额0 / totalSupply 使用余额确保按比例分配
        // 取出来的时候包含了很多个千分之三的手续费
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        // 确认amount0和amount1都大于0
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        // 销毁当前合约内的流动性数量
        _burn(address(this), liquidity);
        // 将amount0数量的_token0发送给to地址
        _safeTransfer(_token0, to, amount0);
        // 将amount1数量的_toekn1发给to地址
        _safeTransfer(_token1, to, amount1);
        // 更新balance0和balance1
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        //如果收费开关是打开的，更新K值
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        // 触发销毁事件
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // swap交换token方法
    // 交换token方法一般通过路由合约调用，功能是交换token，需要的参数包括：amount0Out：token0要交换出的数额；
    // amount1Out：token1要交换出的数额，to：交换token要发到的地址，一般是其它pair合约地址；data用于闪电贷回调使用。
    // 首先确认amount0Out或者amount1Out有一个大于0，然后确保储备量大于要取出的金额。
    // 然后确保address(to)不等于对应的token地址。然后发送token到对应的地址上。
    // 然后data有数据，就执行闪电贷的调用。
    // 之后获取两个token的余额，判断是否在交换之间，有token的输入，如果没有输入就revert。
    // 如果有输入，还需要保证交换之后的储备量的乘积等于k,具体代码中计算公式如下：
    // 代码中的公式这样的原因还是因为Solidity不支持小数运算，上述公式可以改写成如下形态：
    // 其中 相当于k值。这个公式就对应白皮书所写的每次交易收取千分之三的手续费。
    // 最后更新储备量，触发交换事件。
    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        // 确认amount0Out和amount1Out都大于0
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        // 获取储备量0和储备量1
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // 确认取出的量不能大于它的 储备量
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');
        // 初始化变量
        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        // 标记_toekn{0,1}的作用域，避免堆栈太深
        address _token0 = token0;
        address _token1 = token1;
        // 确保to地址不等于token0和token1的地址
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        // 发送token0代币
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        // 如果data的长度大于0，调用to地址的接口
        // 闪电贷
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
        // 余额0，1 = 当前合约在token0，1合约内的余额
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        // 如果余额0 > 储备0 - amount0Out 则 amount0In = 余额0 - （储备0 - amount0Out） 否则amount0In = 0
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        // 确保输入数量0或1大于0
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        // 调整后的余额0 = 余额0 * 1000 - （amount0In * 3）
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        // 确保balance0Adjusted * balance1Adjusted >= 储备0 * 储备1 * 1000000
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }
        // 更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        // 触发交换事件
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // skim方法的功能是强制让余额等于储备量，一般用于储备量溢出的情况下，
    // 将多余的余额转出到address(to)上，使余额重新等于储备量。
    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        // 将当前合约在token1,2的余额-储备量0，1安全发送到to地址上,转账的金额为：余额-储备量
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    //skim方法是强制让余额与储备量对等，sync方法则是强制让储备量与余额对等，直接调用就是更新储备量的私有方法。
    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
