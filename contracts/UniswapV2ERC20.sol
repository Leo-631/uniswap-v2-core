pragma solidity >=0.5.0;

import './interfaces/IUniswapV2ERC20.sol';
import './libraries/SafeMath.sol';

contract UniswapV2ERC20 is IUniswapV2ERC20 {
    //使用using给uint赋能，uint可以调用using里的方法，并且uint自生会作为第一个参数被传进方法
    using SafeMath for uint;
    
    //设置token的名字和标志为'Uniswap V2'和'UNI-V2'
    string public constant name = 'Uniswap V2';
    string public constant symbol = 'UNI-V2';
    //设置token的精度为18位，即除掉后面18个0后的数才是真正的代币个数
    uint8 public constant decimals = 18;

    // token的总供应量
    uint  public totalSupply;

    //定义地址余额
    mapping(address => uint) public balanceOf;

    // 授权交易与授权交易数额之间的映射,谁授权谁多少交易额
    mapping(address => mapping(address => uint)) public allowance;

    // EIP712所规定的DOMAIN_SEPARATOR值，会在构造函数中进行赋值
    bytes32 public DOMAIN_SEPARATOR;
    
    // EIP712所规定的TYPEHASH，这里直接硬编码的keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")所得到的值
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    
    // 地址与nonce之间的映射
    mapping(address => uint) public nonces;

    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    constructor() public {
        
        // 当前运行的链的标识，链ID
        uint chainId;
        assembly {
            // 内联汇编，获取链的标识
            chainId := chainid
        }
        
        // 获取DOMAIN_SEPARATOR
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes(name)),
                keccak256(bytes('1')),
                chainId,
                address(this)
            )
        );
    }
    //铸币方法 这个方法主要的目的是向某个地址发送一定数量的token，注意它是internal函数，所以外部是无法调用的。
    function _mint(address to, uint value) internal {
        totalSupply = totalSupply.add(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(address(0), to, value);
    }
    // 销毁方法 这个方法主要的目的是销毁某个地址的所持有的token。同样它也是internal函数。
    function _burn(address from, uint value) internal {
        balanceOf[from] = balanceOf[from].sub(value);
        totalSupply = totalSupply.sub(value);
        emit Transfer(from, address(0), value);
    }
    // 授权私有方法，修改allowance对应的映射并发出event，注意它是private函数，意味着只能在本合约内直接调用。
    function _approve(address owner, address spender, uint value) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }
    // 转账私有方法 该方法实现了一个转账的逻辑，将from对应的banlanceOf减去value，
    // to对应的balanceOf加上value，最后发出Transferevent
    function _transfer(address from, address to, uint value) private {
        balanceOf[from] = balanceOf[from].sub(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }
    // approve授权方法 直接调用的授权的私有方法，并返回true。
    // 注意它是external（外部）函数，用户通常进行授权操作的外部调用接口。
    function approve(address spender, uint value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }
    // 转账方法 token的拥有这直接调用的方法，将token从拥有者身上转到to地址上去
    function transfer(address to, uint value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }
    //代币授权转移函数，供第三方合约调用，只有被授权过的合约才能调用该方法替你转账
    // 授权转账方法 在执行该方法之前，需要通过approve授权方法或者permit授权方法进行授权。 
    // 转账之前需要确认msg.sender在allowance中是否有值，如果有值就减去对应的金额。
    function transferFrom(address from, address to, uint value) external returns (bool) {
        //uint(-1)来源于C/c++的写法，表示最大的uint,可以理解为0
        if (allowance[from][msg.sender] != uint(-1)) {
            //为什么这里直接减？万一余额不够呢？
            //（解答：这里的减法用的SafeMath中的sub，属于安全的减法，即如果出现不够减，会抛异常，而不会继续往下执行，
            //这样可以减少操作步数和gas）
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(value);
        }
        _transfer(from, to, value);
        return true;
    }
    // permit授权方法 使用线下签名消息进行授权操作
    // [EIP2612](EIP-2612: permit – 712-signed approvals)中的定义。
    // 可以用这个方法实现无gas(token的使用者不需要出gas)的token交易
    // 线下签名不需要花费任何gas，然后任何其它账号或者智能合约可以验证这个签名后的消息，
    // 然后再进行相应的操作（这一步可能是需要花费gas的，签名本身是不花费gas的）。线下签名还有一个好处是减少以太坊上交易的数量，
    // UniswapV2中使用线下签名消息主要是为了消除代币授权转移时对授权交易的需求。
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        // 检查时效时间是否超时
        require(deadline >= block.timestamp, 'UniswapV2: EXPIRED');
        // 构建电子签
        bytes32 digest = keccak256(
            abi.encodePacked(
                '\x19\x01',
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        // 验证签名并获取签名信息的地址
        address recoveredAddress = ecrecover(digest, v, r, s);
        // 确保地址不是0地址并且等于token的owner
        require(recoveredAddress != address(0) && recoveredAddress == owner, 'UniswapV2: INVALID_SIGNATURE');
        // 进行授权
        _approve(owner, spender, value);
    }
}
