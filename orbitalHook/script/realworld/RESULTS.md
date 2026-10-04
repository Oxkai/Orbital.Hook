# Real-world replay: Orbital vs Uniswap v3 on Arbitrum One

Trades: 59 real USDC/USDT0 swaps sampled from 6335 in Uniswap v3 USDC/USDT0 0.01% (0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6), Arbitrum One, blocks 507538701–509957901, replayed in their real order on a fork of Arbitrum One at block 509990147.

Between trades, a rebalancing transaction returns each pool to its pre-trade state, standing in for the arbitrage that keeps mainnet pools at the market price, so every trade meets a pool at the market price. Outputs are the Transfer to the trader in each trade's receipt; gas is the receipt's gasUsed.

Orbital is freshly seeded at exactly 1:1, so before the replay one arbitrage trade moves it to v3's market price (as the first arbitrageur would on mainnet): `0x9b0de6cb…`.

- Filled by both: **53** (4 under $1 are listed but left out of the statistics: at that size one raw unit of rounding is tens of bps)
- Orbital paid more: **20** · v3 paid more: **23**
- Median difference: **+0.00 bps** (+ = Orbital paid more)
- Total paid out on those trades: Orbital **$690,833.41** vs v3 **$690,918.24**
- Median gas: Orbital **256,486** vs v3 **134,661**
- Refused: Orbital 6 · v3 0

## By trade size

Median difference in what the trader received, Orbital vs v3 (+ = Orbital paid more).

| Size | Trades | Median Δ bps | Range |
|---|---:|---:|---|
| $1 – $100 | 31 | +0.00 | -0.00 to +0.01 |
| $100 – $1k | 7 | -0.00 | -0.00 to +0.00 |
| $1k – $10k | 4 | -0.03 | -0.06 to -0.01 |
| $10k – $100k | 3 | -0.21 | -0.35 to -0.11 |
| $100k + | 4 | -1.12 | -2.28 to -1.09 |

## Every trade

| # | Real trade | Size | Direction | v3 paid | Orbital paid | Δ bps | Gas v3 / Orbital |
|---|---|---:|---|---:|---:|---:|---|
| 1 | [0x0c404db8…](https://arbiscan.io/tx/0x0c404db8d82ac8b8407b35cf9e031220942bd3d8929b3d7aecd9f3a79f3a5116) | $150,406.00 | USDC→USDT0 | 150,446.895180 `0x7c091f43…` | 150,430.533092 `0xd29d57f0…` | -1.09 | 194,930 / 440,293 |
| 2 | [0x834f2321…](https://arbiscan.io/tx/0x834f2321e0a8829f3c45bbb1bf7a1b9bbe37ce5c23a156b2faeba863f5759dae) | $1,003.23 | USDT0→USDC | 1,002.702634 `0xf4ada80e…` | 1,002.701783 `0xf9c861cc…` | -0.01 | 134,673 / 256,486 |
| 3 | [0xe3c8e6e6…](https://arbiscan.io/tx/0xe3c8e6e6fd64c500d24d48ea31274f1de8ffef9934190c41e6b89952cf9c6191) | $36,070.49 | USDC→USDT0 | 36,082.037291 `0x47820aa4…` | 36,080.772078 `0x31d19a97…` | -0.35 | 132,799 / 256,392 |
| 4 | [0x56e2ea1f…](https://arbiscan.io/tx/0x56e2ea1f543e83bf2470d431c95a8ff62288db8ea4696e85bfeb46bfe4f54893) | $13.48 | USDC→USDT0 | 13.484711 `0xd52f850d…` | 13.484710 `0x4a7d2604…` | -0.00 | 132,769 / 256,253 |
| 5 | [0x885fbf98…](https://arbiscan.io/tx/0x885fbf98b8454190403945ff41feb7cfaaffa3434d6dba183219ec00e43b859b) | $33.78 | USDT0→USDC | 33.760112 `0xe1c6d09f…` | 33.760115 `0xc6e4d903…` | +0.00 | 134,673 / 261,403 |
| 6 | [0xabed212b…](https://arbiscan.io/tx/0xabed212b551d18c7165476b2450c14941aaa53054f05aa82c26ad6ba704e3df4) | $552.10 | USDT0→USDC | 551.808090 `0xbed9eaf1…` | 551.807863 `0x45abb614…` | -0.00 | 134,673 / 256,442 |
| 7 | [0x82e1f760…](https://arbiscan.io/tx/0x82e1f7605fa8ddd0fdf4296b3f78abc1d200c5185e0628c04c7e0c3ec61915a2) | $273.04 | USDC→USDT0 | 273.127085 `0x5fa17d72…` | 273.126980 `0xc2316bc5…` | -0.00 | 132,781 / 256,380 |
| 8 | [0x346dd651…](https://arbiscan.io/tx/0x346dd651fb74876fd4f35011a9c5c5725eefae7b3e75ffc427922eda20c1521c) | $10.01 | USDT0→USDC | 10.004708 `0xd0c5b9e3…` | 10.004709 `0x1846d8bd…` | +0.00 | 134,661 / 261,391 |
| 9 | [0x03b0b6cd…](https://arbiscan.io/tx/0x03b0b6cd98f349cb74b70262e48b88ced0b8b83793a0da50d347c7571485e87d) | $48.26 | USDC→USDT0 | 48.280414 `0x569b4f59…` | 48.280406 `0x26d9b7a0…` | -0.00 | 132,781 / 256,265 |
| 10 | [0x0113ea11…](https://arbiscan.io/tx/0x0113ea11b7db57e0ec702f4f1a5bb94cb41d7df32ffa940424d535f72660f4f1) | $160,000.00 | USDC→USDT0 | 160,042.662065 `0x10747882…` | 160,024.755120 `0x4737c465…` | -1.12 | 194,918 / 446,336 |
| 11 | [0x87897e6f…](https://arbiscan.io/tx/0x87897e6fda49b6a22c4a6cb937b6b78f1e4ce3d28d99b1f283521e44f1909218) | $8.44 | USDC→USDT0 | 8.439736 `0x15f73ab0…` | 8.439735 `0x54644ef3…` | -0.00 | 132,769 / 256,253 |
| 12 | [0xb4401280…](https://arbiscan.io/tx/0xb44012805e517cb438529e9f383f8b0986bba25f91991cb94b33644bd2eb7270) | $2.97 | USDT0→USDC | 2.968697 `0x83cc241e…` | 2.968699 `0x2144098c…` | +0.01 | 134,661 / 256,430 |
| 13 | [0x71db9692…](https://arbiscan.io/tx/0x71db96929124df5875c7596feee577f12f07eaaed75d974ba502f6337a515b1f) | $1.82 | USDT0→USDC | 1.815004 `0xd84631e7…` | 1.815005 `0xb61bfeae…` | +0.01 | 134,661 / 256,474 |
| 14 | [0xbf7d46c6…](https://arbiscan.io/tx/0xbf7d46c6f7d24f9764a744123269ad9836294385357ecf59dea6bd96b0c94194) | $2.13 | USDT0→USDC | 2.132117 `0x709e3068…` | 2.132118 `0x1d7fb245…` | +0.00 | 134,661 / 261,391 |
| 15 | [0xab2d11b0…](https://arbiscan.io/tx/0xab2d11b0976518d484da4c1e355039d11bc8bec9f73b4d548936eda484d1de99) | $16.02 | USDT0→USDC | 16.014232 `0xa47125dc…` | 16.014235 `0xf8500d6f…` | +0.00 | 134,661 / 261,391 |
| 16 | [0xd60db3b3…](https://arbiscan.io/tx/0xd60db3b3dd95c2f5ef500e41b28545a80cea05a03d8c07a545c41137c749b7bf) | $2.54 | USDC→USDT0 | 2.540373 `0xe868b35e…` | 2.540373 `0x76d9d209…` | +0.00 | 132,769 / 256,297 |
| 17 | [0x2de041b3…](https://arbiscan.io/tx/0x2de041b3d214ec0c888af50293b0c6a72aaf804fc84ae69b10449fd4d08e6863) | $6.74 | USDC→USDT0 | 6.738559 `0x29b6d7b4…` | 6.738558 `0x03ae5eda…` | -0.00 | 132,769 / 256,253 |
| 18 | [0xdf01da5a…](https://arbiscan.io/tx/0xdf01da5a69c6d2dbeb1405d2b24a5862f92abed5575516405cb63b025cd841a0) | $11.13 | USDT0→USDC | 11.123414 `0xa86a5aec…` | 11.123415 `0x0207e277…` | +0.00 | 134,661 / 256,430 |
| 19 | [0xf961e140…](https://arbiscan.io/tx/0xf961e1401bdd4afa7259cdab206516a4b388cedf7eb7f88011696f559d87c525) | $1.25 | USDT0→USDC | 1.248303 `0xf277b117…` | 1.248303 `0xd05c292f…` | +0.00 | 134,661 / 256,430 |
| 20 | [0x9fdaea53…](https://arbiscan.io/tx/0x9fdaea53ed4a9e99a86e53a0a75427bbf38b491e2c7ed82825f5aa8b47e2f411) | $5.71 | USDC→USDT0 | 5.708372 `0x5277a225…` | 5.708372 `0x38cd662d…` | +0.00 | 132,769 / 256,253 |
| 21 | [0xe7ecd13f…](https://arbiscan.io/tx/0xe7ecd13f8c084950b1544b4a000667200028dda0315936ceba41c645527954df) | $4,203.50 | USDT0→USDC | 4,201.273861 `0x1719da14…` | 4,201.257276 `0xea3103b4…` | -0.04 | 134,673 / 261,403 |
| 22 | [0x3eb4cea9…](https://arbiscan.io/tx/0x3eb4cea9a80a80c7785742dca548e6bce794894cd00ec7c2bde68905b0ca36f2) | $62.99 | USDC→USDT0 | 63.013438 `0x62e924af…` | 63.013428 `0x476e9828…` | -0.00 | 132,781 / 261,251 |
| 23 | [0x8d47af0c…](https://arbiscan.io/tx/0x8d47af0c8179b13101285ba5d99536949d27e78a3bef3f670f67e88272640d16) | $54.21 | USDT0→USDC | 54.181344 `0x33d187ad…` | 54.181348 `0x45127a32…` | +0.00 | 134,673 / 261,403 |
| 24 | [0xf25c700d…](https://arbiscan.io/tx/0xf25c700ddf1916c195739cf811413c2ffd78876b3602e0f4d591a0ffff89e861) | $41.76 | USDT0→USDC | 41.739530 `0x4b71ddd3…` | 41.739535 `0x456a48de…` | +0.00 | 134,673 / 256,486 |
| 25 | [0xa54bba9c…](https://arbiscan.io/tx/0xa54bba9ccd2fedb3a23a67bc3e70a953c16e44b650a19d35368d88754776b6e5) | $4.09 | USDT0→USDC | 4.087841 `0x246b7141…` | 4.087842 `0xb09a4f5d…` | +0.00 | 134,661 / 256,430 |
| 26 | [0x223dd619…](https://arbiscan.io/tx/0x223dd6191c09b75c2b3f757200a1dfb2843e60ef2e0c00ebaef1477f285e09e8) | $130.08 | USDC→USDT0 | 130.125244 `0x32c7580b…` | 130.125212 `0x66cb26d6…` | -0.00 | 132,781 / 256,380 |
| 27 | [0x171123c1…](https://arbiscan.io/tx/0x171123c1a389f48c54245d4445d178e9529a75ee57ef07d94b3538c405644de0) | $0.48 | USDC→USDT0 | 0.475397 `0x65d80cd6…` | 0.475398 `0x8d973f1e…` | dust | 132,769 / 261,239 |
| 28 | [0x374c9871…](https://arbiscan.io/tx/0x374c98714b76fd020c93f4dd3457f5c5e2e54e59311fd5b4d04480ef5bfefea9) | $1,770.56 | USDT0→USDC | 1,769.619674 `0x65cbe6f6…` | 1,769.616858 `0x45fc6461…` | -0.02 | 134,673 / 256,486 |
| 29 | [0x6ceac9f0…](https://arbiscan.io/tx/0x6ceac9f09788e041f78c3f96941a0140cfcff6e5febe73b00e7d6cffabfa4c37) | $261,307.18 | USDT0→USDC | 261,139.093896 `0x3bfbb0d8…` | refused | — | — |
| 30 | [0xaf324ca2…](https://arbiscan.io/tx/0xaf324ca22e255409b76aa6a1029b4e007d95fdd0209a270f6dec5073cfc4e03e) | $6,677.82 | USDT0→USDC | 6,674.281425 `0xfa825699…` | 6,674.239087 `0x9c17ad7d…` | -0.06 | 134,685 / 261,415 |
| 31 | [0x0aa9c5b9…](https://arbiscan.io/tx/0x0aa9c5b95facdd5f3ef9711b0207e9a86a26aea6620e41862501c679d6dce8b7) | $249,997.75 | USDT0→USDC | 249,839.694123 `0x67f0b9f3…` | refused | — | — |
| 32 | [0x9a0d326b…](https://arbiscan.io/tx/0x9a0d326b034f5f3345b6df9e8bb07e59673aff6fbeddb8f970e5bba0c1c2010c) | $21,567.35 | USDC→USDT0 | 21,574.330062 `0x799d3ee0…` | 21,573.876660 `0xa8b3e6aa…` | -0.21 | 132,799 / 256,321 |
| 33 | [0xc46f5b8e…](https://arbiscan.io/tx/0xc46f5b8e88613c741a16b2db114e4fb9ceb8e659f69126a81ccad149687d5946) | $11,126.64 | USDC→USDT0 | 11,130.265045 `0x4afef75c…` | 11,130.143706 `0x7c097ad8…` | -0.11 | 132,793 / 261,263 |
| 34 | [0xd96b7f1d…](https://arbiscan.io/tx/0xd96b7f1de1a70d34b96c24f27e9c10c4d1b7f39dd726d9fb1f49479a6792e0c7) | $27.16 | USDT0→USDC | 27.148114 `0xc820c16a…` | 27.148117 `0xeff865e5…` | +0.00 | 134,673 / 256,486 |
| 35 | [0xc440b232…](https://arbiscan.io/tx/0xc440b232159caaade9844095486baad72ccfcabf66052c9bbf03a8d49359bff4) | $306,946.75 | USDT0→USDC | 306,734.431659 `0xd06deb0a…` | refused | — | — |
| 36 | [0xa1e7340f…](https://arbiscan.io/tx/0xa1e7340fafd5c99c236ccf560fef83ad4908b306cd4f7bb1a344bcea8602c42b) | $263,802.35 | USDT0→USDC | 263,632.002551 `0xbf7b1083…` | refused | — | — |
| 37 | [0x143c990f…](https://arbiscan.io/tx/0x143c990f86ff8ebc0fe3070bcfd48901b8c18ce44733c3c88e09980e1d9dc0c2) | $211,215.05 | USDT0→USDC | 211,088.683132 `0xd7d12fe7…` | refused | — | — |
| 38 | [0x073ba74b…](https://arbiscan.io/tx/0x073ba74b25a87ba80fb95a5791bffe12e0546bd3054d2cf93d6c319309eaf684) | $161,521.72 | USDC→USDT0 | 161,564.653477 `0x22f4f4e3…` | 161,546.500772 `0x2527b42f…` | -1.12 | 188,549 / 411,844 |
| 39 | [0x020cf195…](https://arbiscan.io/tx/0x020cf195aa9ec2ac24a4a27c4b76de42752532a2ed631b97ac6c9576b2c7ceef) | $134,028.75 | USDT0→USDC | 133,953.639720 `0x6091b4e6…` | 133,923.136878 `0x5fd9a8eb…` | -2.28 | 134,685 / 390,657 |
| 40 | [0x66e4bfe2…](https://arbiscan.io/tx/0x66e4bfe281c7e4cf3990c2f6f10b8ae4f6785ec7ae15e2a8c5873cd7af19f531) | $330,155.03 | USDT0→USDC | 329,917.575746 `0x7ef6d8ed…` | refused | — | — |
| 41 | [0x14823cbb…](https://arbiscan.io/tx/0x14823cbb311dbdb1c5d9e25bfd7c153a62f19c1aa98a9a6d29a0fcd7555905db) | $1.00 | USDT0→USDC | 0.999471 `0x46bab4bc…` | 0.999471 `0x02587262…` | +0.00 | 134,661 / 256,430 |
| 42 | [0x4b0ccc58…](https://arbiscan.io/tx/0x4b0ccc58c742530d60d40e0e9913533b9f9fb564570de98f6cbcbcb8c67ad537) | $107.81 | USDT0→USDC | 107.755133 `0x356888e9…` | 107.755136 `0xffb8fd2b…` | +0.00 | 134,673 / 256,486 |
| 43 | [0xed60717e…](https://arbiscan.io/tx/0xed60717e72c617755eab04e3ca23d2b0a6f68b04a51e3c541de3e1cd811dfb9f) | $0.79 | USDT0→USDC | 0.792679 `0xf938de44…` | 0.792679 `0xe5e3090d…` | dust | 134,661 / 256,545 |
| 44 | [0x738d9688…](https://arbiscan.io/tx/0x738d968821b896a15a4ba4f23bb1481f67e943219f7961f8227a636c78295378) | $0.14 | USDT0→USDC | 0.140068 `0x9919953b…` | 0.140069 `0x5ed5f9bb…` | dust | 134,661 / 261,391 |
| 45 | [0x3097fc31…](https://arbiscan.io/tx/0x3097fc3143f60f6778615ab5461ef0fa26a03064b11877507b843c8ac0027f98) | $98.00 | USDC→USDT0 | 98.036732 `0x7db6ac73…` | 98.036712 `0xe3f5bc02…` | -0.00 | 132,781 / 256,380 |
| 46 | [0xc0b566a3…](https://arbiscan.io/tx/0xc0b566a3ed1f789e2b69783bfeff553ac1769748944d26180ec9f30dc74e6f3a) | $22.50 | USDT0→USDC | 22.488106 `0xbaf8ab93…` | 22.488108 `0xc41785d3…` | +0.00 | 134,673 / 256,557 |
| 47 | [0x92284599…](https://arbiscan.io/tx/0x92284599f078d68a079ab5bd11d007865dfae7719967a4109c24615f86a93a12) | $203.88 | USDT0→USDC | 203.774140 `0xfe4558b0…` | 203.774126 `0xc7169c2a…` | -0.00 | 134,673 / 256,486 |
| 48 | [0x876c55f8…](https://arbiscan.io/tx/0x876c55f8fcbe85c5af8ddd25da82d82a9890c54510a072a6b6d1dfd08ee2f763) | $60.81 | USDT0→USDC | 60.781007 `0xf0cf11eb…` | 60.781012 `0xbb8bef2c…` | +0.00 | 134,673 / 256,486 |
| 49 | [0xe1bc2a6c…](https://arbiscan.io/tx/0xe1bc2a6ca16385181cdd48b4635021b3923646b8e59505719381cb0ae9ed7e35) | $160.80 | USDC→USDT0 | 160.854266 `0x56af5b3c…` | 160.854222 `0x83e39a14…` | -0.00 | 132,781 / 256,380 |
| 50 | [0x2f686d28…](https://arbiscan.io/tx/0x2f686d28a37965d3da838384e0bdb7f400fda3be20dd84e50616ab7c6b35b1a4) | $0.00 | USDT0→USDC | 0.000074 `0x855d78af…` | 0.000075 `0xe3a5ecfc…` | dust | 129,534 / 251,374 |
| 51 | [0x1fbb0b9f…](https://arbiscan.io/tx/0x1fbb0b9f9906442167777db183081b95a457cf0584960b6b5819a5b3ab299b47) | $5.00 | USDC→USDT0 | 5.001643 `0xef5e527c…` | 5.001643 `0xc56a226a…` | +0.00 | 132,769 / 261,239 |
| 52 | [0xf90496c5…](https://arbiscan.io/tx/0xf90496c55431541b17316d95e23d1fe521a4692de450baa3898efb79217acf4c) | $80.00 | USDT0→USDC | 79.957710 `0x0f0c34b9…` | 79.957714 `0x794e31eb…` | +0.00 | 134,661 / 261,391 |
| 53 | [0x258f914c…](https://arbiscan.io/tx/0x258f914c4f10c66ada2568380451bce406f4bda5b5ac7199748906509da601e9) | $380.05 | USDT0→USDC | 379.846876 `0x92b271da…` | 379.846783 `0x1b87e15f…` | -0.00 | 134,673 / 256,557 |
| 54 | [0xe5e12638…](https://arbiscan.io/tx/0xe5e12638c42920e4686d6227e3aa0c6a19a007e25a0cd7678793c9538fd1322a) | $1.50 | USDT0→USDC | 1.499207 `0xa8509f84…` | 1.499207 `0x88ecfacc…` | +0.00 | 134,661 / 256,474 |
| 55 | [0x73f402e5…](https://arbiscan.io/tx/0x73f402e5c795d0fea52f338e766cffed0e17aa8eb696929b9c7694078bafc9b4) | $9.69 | USDT0→USDC | 9.682086 `0x63c55ea8…` | 9.682087 `0x82152e26…` | +0.00 | 134,661 / 256,545 |
| 56 | [0x8d03540d…](https://arbiscan.io/tx/0x8d03540d7c2f70b5f66429963e5949c0557500a573c6fb5ae59f9cca74c3ee66) | $3.45 | USDT0→USDC | 3.447010 `0xbe5691e3…` | 3.447011 `0x34e7d761…` | +0.00 | 134,661 / 261,391 |
| 57 | [0xcbe6ea5a…](https://arbiscan.io/tx/0xcbe6ea5a724dbc82e62b5d29de79c3da20b0a16635d1f5e33314f3920ee9bf7c) | $7.52 | USDT0→USDC | 7.520664 `0xebf4debd…` | 7.520666 `0x9e1b3b3a…` | +0.00 | 134,661 / 256,545 |
| 58 | [0x180b2c95…](https://arbiscan.io/tx/0x180b2c95fcd5d375d280aa76844178c4061db706802909895b010c6655e6fa19) | $19.94 | USDT0→USDC | 19.929459 `0xea191c5c…` | 19.929461 `0xe334bfb3…` | +0.00 | 134,673 / 261,403 |
| 59 | [0xa45bab23…](https://arbiscan.io/tx/0xa45bab23870ebc2c7988ba157331f648aac3377632e04e3f293052d9cc7da872) | $4.82 | USDT0→USDC | 4.817782 `0xc6e68e28…` | 4.817783 `0x5393058b…` | +0.00 | 134,661 / 261,391 |

## Refusals

- #29 orbital: `0x6190b2b00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000010490bfb865000000000000000000000000664c790c5297f720cee008a66b25d3`
- #31 orbital: `0x6190b2b00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000010490bfb865000000000000000000000000664c790c5297f720cee008a66b25d3`
- #35 orbital: `0x6190b2b00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000010490bfb865000000000000000000000000664c790c5297f720cee008a66b25d3`
- #36 orbital: `0x6190b2b00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000010490bfb865000000000000000000000000664c790c5297f720cee008a66b25d3`
- #37 orbital: `0x6190b2b00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000010490bfb865000000000000000000000000664c790c5297f720cee008a66b25d3`
- #40 orbital: `0x6190b2b00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000010490bfb865000000000000000000000000664c790c5297f720cee008a66b25d3`
