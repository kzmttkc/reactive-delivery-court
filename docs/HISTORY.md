# History

Earlier stages of Delivery Court, kept for the record. The current contracts, scenes and live server are in the [README](../README.md).

## v1 pair (model judge, both networks, 2026-11-21)

Replaced on 2026-11-22 by the v2 pair, which re-scores the judge's facts on chain (see the README). Record: `deployments/stage3.json`. Setup transactions: "Setup transactions (model judge and x402 sellers)" below.

| Contract | Chain | Address |
|---|---|---|
| DeliveryCourtReactive | Lasna | [`0x9BB13974e4B1e2f3C8e8855c9637a8Ee490eCcb5`](https://lasna.reactscan.net/address/0x9BB13974e4B1e2f3C8e8855c9637a8Ee490eCcb5) |
| DeliveryCourtCallback | Base Sepolia | [`0xD877aBeED8BaECEeB688115170228a203E39F0DB`](https://sepolia.basescan.org/address/0xD877aBeED8BaECEeB688115170228a203E39F0DB) |

The v1 callback source is verified on Sourcify with a full match (creation and runtime): https://sourcify.dev/server/v2/contract/84532/0xD877aBeED8BaECEeB688115170228a203E39F0DB . Verified 2026-11-21 13:19 UTC, job 9b29cd74-8733-482f-819e-8cf2e7ab8963. Sourcify forwarded it to Blockscout (guid d877abeed8baeceeb688115170228a203e39f0db6b019a46). Before that, `forge verify-contract` to Blockscout was submitted twice on Nov 21 without a confirmed result.

Scenes on the v1 pair, model version `sha256:71d5a10978ed1106eceae249f3361f7018b718868fc3448881910ff454d90250`, run on 2026-11-21 (UTC) with `node src/run-scenes.mjs deliver empty silent`. Records: `offchain/runs/v1/`.

| Scene | x402 payment: `authorize` (Base Sepolia) | Deposited react (Lasna) | Seller request, model score (Base Sepolia) | Decision react (Lasna) | Callback (Base Sepolia) | Buyer / seller USDC before, held, after |
|---|---|---|---|---|---|---|
| Delivering seller (200, JSON body), capture | [0x3014941c…cdd68f](https://sepolia.basescan.org/tx/0x3014941c496b13558d014c845c88e1bcea49d75fde35efd3783452e316cdd68f) | [0x4a55b1b2…9d90ab](https://lasna.reactscan.net/tx/0x4a55b1b2d3f5519c50ce0f795943bf9ec8e4462d33b112fa4314685cc69d90ab) | request [0x35eca333…48d589](https://sepolia.basescan.org/tx/0x35eca333b31101194967d38f2b48c4ff7e27e8c7939ab457a5c264bde348d589), score 99 [0x79a1e635…bca5ec](https://sepolia.basescan.org/tx/0x79a1e63596159022441e0fac1ce2ae56a5d3bf6bf3db7742a8fa52dc5bbca5ec) | [0x54eeab3a…b23b9e](https://lasna.reactscan.net/tx/0x54eeab3af7399eda6fe150ced4685cb4e8992fa79873f70a4a7f361a0cb23b9e) | capture [0x68c5b380…5d413c](https://sepolia.basescan.org/tx/0x68c5b3807f8a43228fa008170786503d02690b0ec3f600bc02e727ab2a5d413c) | 1.99 / 0.01, 1.98 / 0.01, 1.98 / 0.02 |
| Empty body (200, 0 bytes), refund and feedback | [0xef8d9baa…7919ef](https://sepolia.basescan.org/tx/0xef8d9baa8d924533cf2c9823c9642f1eac423b807303c6b41ac3b0d1ad7919ef) | [0x99adaa93…799625](https://lasna.reactscan.net/tx/0x99adaa93187cef7b4441caf18dde65482e3ac019b4873079706a81a642799625) | request [0x211f7119…0c217c](https://sepolia.basescan.org/tx/0x211f7119d3a3e5678bb3097a04ab00d4c7867683654809625f51bc98bd0c217c), score 0 [0x00b6ed6b…ab3df1](https://sepolia.basescan.org/tx/0x00b6ed6b08afe5a62994e96df471d8bdb26bee31be5947b21f919a1465ab3df1) | [0xd20c0483…1cfd07](https://lasna.reactscan.net/tx/0xd20c04831bb71994446277fab01572e269961caa4f2d856ee3fdf804981cfd07) | void + ERC-8004 feedback [0x879a6225…daf293](https://sepolia.basescan.org/tx/0x879a622546bacee963c80b9a7e0f7cbd2ced1066b73f3466cc718c8617daf293) | 1.98 / 0.00, 1.97 / 0.00, 1.98 / 0.00 |
| Silent seller (no answer), cron refund | [0xf1b759d8…e11cf0](https://sepolia.basescan.org/tx/0xf1b759d8353e42bbe2140324e41d3b7655d3ff2701b647ebb45744e070e11cf0) | [0x53daf7bb…ca8dcd](https://lasna.reactscan.net/tx/0x53daf7bb88d8f598249ac8d7fd878132164d1444025bbb0ee74aba6a4dca8dcd) | n/a (no answer, no request) | [0x82d02b5d…4f9cd1](https://lasna.reactscan.net/tx/0x82d02b5d97dc5e4608da01a8b0d997a5a94b4d62fbe51800ea2d0056564f9cd1) | void [0xa1f7b089…f638fc](https://sepolia.basescan.org/tx/0xa1f7b08944a74c754e62a38fdbbce8f5bdfab72057bfaa5d866ecb5f43f638fc) | 1.98 / 0.00, 1.97 / 0.00, 1.98 / 0.00 |

The silent refund came 85 s after payment (Base Sepolia blocks 61719922 → 61720348, timestamps 1795265853 → 1795265938). On v1 the judge wrote the tag `"delivery"` and the reactive contract took the judge's score as it was.

Bodies on chain and in the repo (v1):

| Scene | Body file | sha256 of the file | `responseHash` in the judgment tx | `responseURI` in the judgment tx | Match |
|---|---|---|---|---|---|
| deliver | [`offchain/runs/v1/deliver.body`](../offchain/runs/v1/deliver.body) (151 bytes) | `0x538cad3c…437861` | `0x538cad3c…437861` ([tx](https://sepolia.basescan.org/tx/0x79a1e63596159022441e0fac1ce2ae56a5d3bf6bf3db7742a8fa52dc5bbca5ec)) | `offchain/runs/responses/0x172433b8829672992352e958013643d1b7aadda441641a3ad2bd39b3f1225711.json` | yes |
| empty | [`offchain/runs/v1/empty.body`](../offchain/runs/v1/empty.body) (0 bytes) | `0xe3b0c442…52b855` | `0xe3b0c442…52b855` ([tx](https://sepolia.basescan.org/tx/0x00b6ed6b08afe5a62994e96df471d8bdb26bee31be5947b21f919a1465ab3df1)) | `offchain/runs/responses/0xd83050a25bb6ac83cb74d177c407500d82f358ea3bb12d7f98ef9a6a4259d8a4.json` | yes |

Latency on v1, 30 delivering runs on 2026-11-21 (UTC): median 5 s, p95 11 s, min 4 s, max 12 s (`offchain/runs/v1/latency/summary.json`).

First runs on the live server on v1 (2026-11-21 UTC): a server-paid delivery scored 99 and captured in [0x91450b0a…ff6211](https://sepolia.basescan.org/tx/0x91450b0a223d5528c2f67ec354b56d4d8fbf5622c3192499b930ffb96aff6211), and a payment to the empty seller made with `src/pay.mjs` (the project buyer key, the same path as an outside wallet) and posted to `/judge` scored 0 and voided in [0x3a6c73ef…20557b](https://sepolia.basescan.org/tx/0x3a6c73ef2194fe91c9bd3a3c215fce89294d22c6588cfa5a7be679c44020557b).

Balances on v1, measured on 2026-11-21 after the runs: reactive 1.86 lREACT (2.88 before the 33 runs, about 0.03 lREACT per paid run), debt 0, cron paused. Callback reserve 0.000959 ETH, debt 0.

Known limits of v1, fixed in v2: `authorize` was open to any seller with any amount and expiry, and the cron scanned at most 32 queued payments past the first undecided one without wrapping (H2). One threshold (70) decided both the refund and the ERC-8004 feedback, so a low score also left a review (M4).

## Deployed addresses (first pair)

First pair (stage 0, manual judgment from the deployer account):

| Contract | Chain | Address |
|---|---|---|
| DeliveryCourtReactive | Lasna | [`0x025E54B9045fFAF4327860b1Bd6B992b04c20938`](https://lasna.reactscan.net/address/0x025E54B9045fFAF4327860b1Bd6B992b04c20938) |
| DeliveryCourtCallback | Base Sepolia | [`0xED4123D5D7b2102106042b04af0f3268A537eB79`](https://sepolia.basescan.org/address/0xED4123D5D7b2102106042b04af0f3268A537eB79) |

The validator is immutable in the reactive contract, so moving the judgment to its own account needed a new pair.

## First model judge, metadata network only (history)

Model version `sha256:efaddc9688c6099dc6b3061c422dc500596bf2812e4de6b725bb71a55958945d` (`model/model.json` alone). In these runs `responseURI` was a `data:` JSON record and the bodies were not stored in the repo. Records: `offchain/runs/history/*-v1.json`.

| Scene | x402 payment: `authorize` (Base Sepolia) | Deposited react (Lasna) | Seller request, model score (Base Sepolia) | Decision react (Lasna) | Callback (Base Sepolia) | Buyer / seller USDC before, held, after |
|---|---|---|---|---|---|---|
| Delivering seller (200, JSON body), capture | [0x1cbeaedd…278961](https://sepolia.basescan.org/tx/0x1cbeaedd64eb27bb4b3111d0db8f5683e7b1694b4ec1a6f6d8ad025716278961) | [0x7f492e28…e37a97](https://lasna.reactscan.net/tx/0x7f492e28435c84eeae80d23fed981f3ecca2aff228f5ae71e60eb0d5d0e37a97) | request [0x6bf6e147…927d6c](https://sepolia.basescan.org/tx/0x6bf6e1474de7f39522f283c94e3d70b27e9f7ec967c0e4cf39083e6a50927d6c), score 100 [0x444d6b41…c8fdd1](https://sepolia.basescan.org/tx/0x444d6b416fee1f668289135c6781cafc721728771ba6ccccefefa08090c8fdd1) | [0xbe0f0b5a…86e0ce](https://lasna.reactscan.net/tx/0xbe0f0b5aacedbc52d38df1e4d2e48043219220e060517527977e439ad686e0ce) | capture [0x44110f64…948455](https://sepolia.basescan.org/tx/0x44110f64fbe9e096e89f50bd8865264ccf045fe87beb7b24e8a0e04a6f948455) | 2.00 / 0.00, 1.99 / 0.00, 1.99 / 0.01 |
| Empty body (200, 0 bytes), refund and feedback | [0xe0630d8f…9524a0](https://sepolia.basescan.org/tx/0xe0630d8f9b267319e97eb0249941d023e436c27b995966e4c0c37491e99524a0) | [0xae2c88f8…ba4801](https://lasna.reactscan.net/tx/0xae2c88f88bad635a87035360624d216ee116ecc0bd901ced4cc83274dbba4801) | request [0x1d88ec9b…4ad057](https://sepolia.basescan.org/tx/0x1d88ec9b0b7a7fe2aeb21461ddd9c98bff77e7b7160c7e968bcab07f064ad057), score 3 [0x02ed4f88…adb60a](https://sepolia.basescan.org/tx/0x02ed4f88de0165cc72082a69663dbfff8c98801cc80d053b2a7de6827cadb60a) | [0xf17a8a98…a5bfc4](https://lasna.reactscan.net/tx/0xf17a8a985f4144a5e3f16efbb0c5185cfa703dae48002c821905b5c049a5bfc4) | void + ERC-8004 feedback [0x348f2db5…bd0a5c](https://sepolia.basescan.org/tx/0x348f2db5c5e0cba9655a7787b913a9cfa6f44cd56e80f22d37e7e51737bd0a5c) | 1.99 / 0.00, 1.98 / 0.00, 1.99 / 0.00 |
| Silent seller (no answer), cron refund | [0x0b5ed13d…3141f2](https://sepolia.basescan.org/tx/0x0b5ed13d7f07eab218a6f956e0f37f917461c2a5bd994c11938049720e3141f2) | [0x97334baf…f598bb](https://lasna.reactscan.net/tx/0x97334baf50583a6bddebff3108c4ce77f46c30d7d7abc2688162e73e0af598bb) | n/a (no answer, no request) | [0x1b8443cf…9b3518](https://lasna.reactscan.net/tx/0x1b8443cfe4e0b3b7f959c2e138c86f86cba5e6798522dab3424712b84e9b3518) | void [0xd3ce6b94…826e76](https://sepolia.basescan.org/tx/0xd3ce6b94d772640223bca9e4b2f67c8ec3c766aca0224166551cb22d3e826e76) | 1.99 / 0.00, 1.98 / 0.00, 1.99 / 0.00 |

## First manual judgment (stage 0)

The first loop on testnet, with the score typed by hand from the deployer account.

| Scene | Payment (Base Sepolia) | Deposited react (Lasna) | Validation response (Base Sepolia) | Decision react (Lasna) | Callback (Base Sepolia) |
|---|---|---|---|---|---|
| Delivering seller, capture | [0xbaeb632f…7c6077](https://sepolia.basescan.org/tx/0xbaeb632fe2a6708747d1d1354b2102db71f62b6ad31afe617c0cfb2e997c6077) | [0xe9a5eb3d…7ae06](https://lasna.reactscan.net/tx/0xe9a5eb3d4c57b404ebfa19f027f04d458a02d619fbd9ec67c0f2ca3021d7ae06) | request [0x4ba0af1c…052e39](https://sepolia.basescan.org/tx/0x4ba0af1c4ee87290d42c5482cf71ebcc797f8495ff1f895718e4408923052e39), score 90 [0xbeec7c6f…e99a59](https://sepolia.basescan.org/tx/0xbeec7c6fd3210f1e42637388096db1683b6a2788db1edaf9cf2c0da1f7e99a59) | [0xd228dd06…0aece9](https://lasna.reactscan.net/tx/0xd228dd06b64abb6ea479c55e77d7d57d0f4d500216795a222f876b46cd0aece9) | capture [0xfac9cbe3…33a236](https://sepolia.basescan.org/tx/0xfac9cbe3d5cc8180da88033631c80103f0a335d5664a12b7b2416f05d133a236) |
| Empty body, refund and feedback | [0x6ff536e7…bf72d5](https://sepolia.basescan.org/tx/0x6ff536e735c29e261116f91e1294215e34d7fa6e150995593fee7e945fbf72d5) | [0xa0ace5a9…a94cf5](https://lasna.reactscan.net/tx/0xa0ace5a9eb090afd87eecbe4273600e1410f14b104ed2fb927bc1106d3a94cf5) | request [0x526d0347…483f9e](https://sepolia.basescan.org/tx/0x526d0347f592aba3b51cfd1cb059fd3dfc01f0a45af14600fe4bb21f84483f9e), score 10 [0x2af45fea…edfcf](https://sepolia.basescan.org/tx/0x2af45feadd8762f967454fdde83c5c9734353ddfc3449ca61989f8f5aadedfcf) | [0x1518a495…2772a3](https://lasna.reactscan.net/tx/0x1518a495e5ed20cbc2595b83be9a4e7b5eddfc68bda04672d2b778891b2772a3) | void + ERC-8004 feedback [0xc84369fe…9bea1d](https://sepolia.basescan.org/tx/0xc84369fe778dd6bf1f696d8b12fc3fcf48887a53be89744f78c14c03129bea1d) |
| Silent seller, cron refund | [0x76ad264c…2c17b9](https://sepolia.basescan.org/tx/0x76ad264c8b4cc09ac2bcb1feef95d1eb274d7a297c33183cc7c4bb66f32c17b9) | [0x0a974bbf…d43f7b](https://lasna.reactscan.net/tx/0x0a974bbff93bdd5e6a226e1a24eab68d4b20a103b6bde712f70d0f2952d43f7b) | n/a | cron tick [0x2e38b986…2771e7](https://lasna.reactscan.net/tx/0x2e38b986de214608d5097196312aeb94b0bef7d14f95d7a4d9d6a5952e2771e7) | void [0x4b130cb0…06d2d4](https://sepolia.basescan.org/tx/0x4b130cb07bfc550174cbb6c83bee6f622b1c0e500c48b583ba0e0b8c4f06d2d4) |

## Setup transactions (stage 0)

| Step | Chain | Tx | Status |
|---|---|---|---|
| 0.3 ETH to the lREACT faucet (31.5 lREACT arrived on Lasna) | Ethereum Sepolia | [0xef66d6bc…775c7d](https://sepolia.etherscan.io/tx/0xef66d6bca1077baba2575d4d140b5ae9efc65ae919b5d07d7c1808f155775c7d) | success |
| 0.02 ETH bridged to Base Sepolia (official L1StandardBridge) | Ethereum Sepolia | [0x78742514…df89df](https://sepolia.etherscan.io/tx/0x78742514e1beb064d05b26b1dbb0c7cfed52896970e06ceb4a27a9be58df89df) | success |
| Deploy DeliveryCourtReactive with 5 lREACT | Lasna | [0x14e39d86…3f9757](https://lasna.reactscan.net/tx/0x14e39d86847659bb1b348707cf0eb7bc6af88ef6d6a938c81f2ff95a423f9757) | success |
| pauseCron (cron off while idle) | Lasna | [0x99c7fe36…21478e](https://lasna.reactscan.net/tx/0x99c7fe3613d2fbe1b8d75eb7119987d920c7c4d0ff44cf6424ffd2fb7b21478e) | success |
| Deploy DeliveryCourtCallback (callback sender = the reactive contract) | Base Sepolia | [0x6ec11090…68b569](https://sepolia.basescan.org/tx/0x6ec1109002acbd167796b086955d8da3cd64729e3cba29270cef66052b68b569) | success |
| setCourt (subscribe to Deposited) | Lasna | [0x0f0a8093…6cb2013](https://lasna.reactscan.net/tx/0x0f0a80937f70514677c75b54898d942d3600e772aa53d56a58fb6931c6cb2013) | success |
| depositTo 0.001 ETH for callback gas (callback proxy) | Base Sepolia | [0xfa691817…e3786b](https://sepolia.basescan.org/tx/0xfa69181737ab35a43f8fbbe71e8ebcf4554f11d4f31092e0ab78497ba4e3786b) | success |
| resumeCron (for the silent-seller scene) | Lasna | [0x94d7cb08…2baf1](https://lasna.reactscan.net/tx/0x94d7cb08cdf2f43e3c57b83bbb405cd59303886a60472f535767fe5caef2baf1) | success |
| pauseCron after the scenes | Lasna | [0x2e8458d3…fb42a2d](https://lasna.reactscan.net/tx/0x2e8458d39282e463123ba74ec9b90b9f7a4d571916e8b527cf5c82a25fb42a2d) | success |

## Setup transactions (model judge and x402 sellers)

| Step | Chain | Tx | Status |
|---|---|---|---|
| 0.001 ETH to relayer | Base Sepolia | [0x9ecc3bf1…9560db](https://sepolia.basescan.org/tx/0x9ecc3bf113404b877d0dd7e19fb9c04a09a5a69135614e1c1f240f17e39560db) | success |
| 0.001 ETH to judge | Base Sepolia | [0xc7739b62…cc53bb](https://sepolia.basescan.org/tx/0xc7739b62e5f4b07e63fb73764571d375a340238fb6cef3415d9c83f5f4cc53bb) | success |
| 0.001 ETH to seller-deliver | Base Sepolia | [0x860ad6fb…14fe64e](https://sepolia.basescan.org/tx/0x860ad6fb10eb155c244bb6201337509aa151803ad40a14247cb22da9214fe64e) | success |
| 0.001 ETH to seller-empty | Base Sepolia | [0xbe46b01d…d12bcc](https://sepolia.basescan.org/tx/0xbe46b01d62273a6fc9be8ff2d895bfa128e831849f6dcc8d08a91d26f1d12bcc) | success |
| 0.0005 ETH to seller-silent | Base Sepolia | [0x64843de1…be4583](https://sepolia.basescan.org/tx/0x64843de10d7131e56e4a121b701e89fe712b7dfb848c885029047e7d5dbe4583) | success |
| 0.0005 ETH to buyer | Base Sepolia | [0x36e37b98…4dd7c2](https://sepolia.basescan.org/tx/0x36e37b981e732bcb22b42e9a716d3939834961222d62bb601e390d21da4dd7c2) | success |
| 2 USDC to buyer | Base Sepolia | [0xc0391132…8cb1c5](https://sepolia.basescan.org/tx/0xc0391132f62c96119ae71e6a3483bcf79671e68f1cac970d95869f727a8cb1c5) | success |
| Deploy DeliveryCourtReactive (validator = judge) with 3 lREACT | Lasna | [0xaf75b392…e28a44](https://lasna.reactscan.net/tx/0xaf75b39246c563721b041307729b98955a20bfb07864ff53041e1c8446e28a44) | success |
| pauseCron right after deploy | Lasna | [0xf12c811d…36d623](https://lasna.reactscan.net/tx/0xf12c811d50f08f62e53083bcdd64b5f3795e7b885383cea02c3b1730f736d623) | success |
| Deploy DeliveryCourtCallback | Base Sepolia | [0x3d514fc5…055f35d](https://sepolia.basescan.org/tx/0x3d514fc533ee32bea9ff7764a34acb4ba41e43969c01acd2ad9c98385055f35d) | success |
| setCourt | Lasna | [0x144f42b0…5522be](https://lasna.reactscan.net/tx/0x144f42b01ac32bcfb20b96cd6a973f441e617db79c7334cc4ced09c7f35522be) | success |
| depositTo 0.001 ETH for callback gas | Base Sepolia | [0xe082e9d8…cf40bb](https://sepolia.basescan.org/tx/0xe082e9d8ec98ccba57401c00ed7ae10a2ea5b31e9e2909b2912980e5a0cf40bb) | success |
| ERC-8004 register seller-deliver (agent 10798) | Base Sepolia | [0xa4db3259…f58bab](https://sepolia.basescan.org/tx/0xa4db325926fd3d346f86b3b00bf38c80935cde1164f4e76fa526649da2f58bab) | success |
| ERC-8004 register seller-empty (agent 10799) | Base Sepolia | [0x9ba0d5f1…3d6f32](https://sepolia.basescan.org/tx/0x9ba0d5f12245eff7aea85b8bd6c08c0b5ecc0761d00361d90be8cf540b3d6f32) | success |
| resumeCron (for the silent-seller scene) | Lasna | [0xdf79d534…978dda](https://lasna.reactscan.net/tx/0xdf79d5341cc2a74abf1fcee006f215f4809e0b7be4a4dac1ca31a1baa4978dda) | success |
| pauseCron after the scene | Lasna | [0xa9d4bcfc…5cfc36](https://lasna.reactscan.net/tx/0xa9d4bcfc4c228030466d5a8e0b6ca6442af950dabb3404124966b32dcc5cfc36) | success |
| resumeCron (silent-seller scene, both networks) | Lasna | [0xbd595f43…fdfb66](https://lasna.reactscan.net/tx/0xbd595f4382ede7548193381cd9051658418b2e156e29995721a1480b48fdfb66) | success |
| pauseCron after the scene | Lasna | [0xf0a44ef1…039c4d](https://lasna.reactscan.net/tx/0xf0a44ef150db30386fd3b9492593782eca9567c538cd59497a49d01a13039c4d) | success |
