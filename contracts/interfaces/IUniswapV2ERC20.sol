pragma solidity >=0.5.0;

interface IUniswapV2ERC20 {
    // 这两个event分别会在授权和转账的时候触发
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    // 定义token名字的方法
    function name() external pure returns (string memory);
    // 定义token标志的方法
    function symbol() external pure returns (string memory);
    // 定义token所支持的精度位数方法
    function decimals() external pure returns (uint8);
    // 定义当前token的总供应量方法
    function totalSupply() external view returns (uint);
    // 定义查询当前地址余额的方法
    function balanceOf(address owner) external view returns (uint);
    // 定义查询owner允许spender交易的token数量方法
    function allowance(address owner, address spender) external view returns (uint);
    // 定义授权方法，token的拥有者向spender授权交易指定value数量的token
    function approve(address spender, uint value) external returns (bool);
    // 定义交易方法
    function transfer(address to, uint value) external returns (bool);
    // 定义授权交易方法，这个方法一般是spender调用
    function transferFrom(address from, address to, uint value) external returns (bool);
    // 定义DOMAIN_SEPARATOR方法，这个方法会返回[EIP712]
    // (EIP-712: Ethereum typed structured data hashing and signing)
    // 所规定的DOMAIN_SEPARATOR值
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    // 定义PERMIT_TYPEHASH方法,这个方法会返回[EIP2612](EIP-2612: permit – 712-signed approvals)
    // 所规定的链下信息加密的类型
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    // 定义nonces方法，这个方法会返回EIP2612所规定每次授权的信息中所携带的nonce值是多少，
    // 可以方式授权过程遭受到重放攻击。
    function nonces(address owner) external view returns (uint);
    // 定义permit方法，这个方法就是EIP2612进行授权交易的方法，
    // 可以用这个方法实现无gas(token的使用者不需要出gas)的token交易
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
}
