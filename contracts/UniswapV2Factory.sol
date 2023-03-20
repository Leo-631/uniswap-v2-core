pragma solidity >=0.5.0;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    // address(feeTo)表示平台手续费收取的地址
    address public feeTo;
    // address(feeToSetter)则表示可设置平台手续费收取地址的地址
    address public feeToSetter;

    // getPair的类型是map,存放Pair合约两个token与Pair合约的地址,用于通过两个token查询pair地址
    mapping(address => mapping(address => address)) public getPair;
    // 变量allPairs存放所有Pair合约的地址。
    address[] public allPairs;

    // 当Pair合约被创建之后，会触发该事件。
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    // Factory合约的构造函数需要传入权限控制人的address。
    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    // 查询Pair数组长度方法
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    // 创建Pair方法
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        //检查地址是否存在的过程消耗较高，所以通过比较排序后只检查一个可以节省费用(猜测)
        //对于给定的 tokenA 和 tokenB，会先将其地址排序，将地址值更小的放在前，这样方便后续交易池的查询和计算。（官方解释，目前还没看出方便在哪）
        //解答为什么一定要排序，因为避免在后面创建合约的时候，把token0和token1传入时，调用者传入的顺序不对，导致合约地址改变
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        //检查地址是否存在（为什么只检测token(0)，不检查token(1)）
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        //提前检查Pool地址是否存在，不存在才继续创建pool
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        //使用UniswapV2Pair的合约二进制字节码和token0、token1
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        //内联汇编
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        //uniswapV3版本使用的create2不在需要内联汇编，
        // 即solidity大于0.7.6版本后就不需要内联汇编，可以通过指定 slat 来使用 create2
        //这里传入的token0和token1就是排过序的。
        //本来打算换成V3的写法，结果由于UniswapV2ERC20.sol中的内联汇编需要用到0.5.16版本，所以这里也不能直接换V3版本的写法。
        // pair = address(new UniswapV2Pair{salt: keccak256(abi.encode(token0, token1))}());
        IUniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    // 设置平台手续费收取地址
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    // 平台手续费收取权限控制
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
