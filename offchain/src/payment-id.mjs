// paymentId = AuthCaptureEscrow.getHash(paymentInfo), rebuilt from an x402 auth-capture payload.
import { encodeAbiParameters, keccak256, toBytes, getAddress } from "viem";

const PAYMENT_INFO_TYPEHASH = keccak256(
  toBytes(
    "PaymentInfo(address operator,address payer,address receiver,address token,uint120 maxAmount,uint48 preApprovalExpiry,uint48 authorizationExpiry,uint48 refundExpiry,uint16 minFeeBps,uint16 maxFeeBps,address feeReceiver,uint256 salt)",
  ),
);

export function escrowHash(chainId, escrow, info) {
  const inner = keccak256(
    encodeAbiParameters(
      [
        { type: "bytes32" },
        { type: "address" }, { type: "address" }, { type: "address" }, { type: "address" },
        { type: "uint120" }, { type: "uint48" }, { type: "uint48" }, { type: "uint48" },
        { type: "uint16" }, { type: "uint16" }, { type: "address" }, { type: "uint256" },
      ],
      [
        PAYMENT_INFO_TYPEHASH,
        info.operator, info.payer, info.receiver, info.token,
        BigInt(info.maxAmount), BigInt(info.preApprovalExpiry), BigInt(info.authorizationExpiry), BigInt(info.refundExpiry),
        Number(info.minFeeBps), Number(info.maxFeeBps), info.feeReceiver, BigInt(info.salt),
      ],
    ),
  );
  return keccak256(encodeAbiParameters([{ type: "uint256" }, { type: "address" }, { type: "bytes32" }], [BigInt(chainId), escrow, inner]));
}

/** paymentPayload: decoded x402 v2 payload with `accepted` (the chosen requirements) and `payload` (eip3009 form). */
export function paymentInfoFromPayload(paymentPayload) {
  const req = paymentPayload.accepted;
  const p = paymentPayload.payload;
  const extra = req.extra;
  return {
    operator: getAddress(extra.captureAuthorizer),
    payer: getAddress(p.authorization.from),
    receiver: getAddress(req.payTo),
    token: getAddress(req.asset),
    maxAmount: req.amount,
    preApprovalExpiry: p.authorization.validBefore,
    authorizationExpiry: extra.captureDeadline,
    refundExpiry: extra.refundDeadline,
    minFeeBps: extra.minFeeBps,
    maxFeeBps: extra.maxFeeBps,
    feeReceiver: getAddress(extra.feeRecipient),
    salt: p.salt,
  };
}

export function paymentIdFromPayload(chainId, escrow, paymentPayload) {
  return escrowHash(chainId, escrow, paymentInfoFromPayload(paymentPayload));
}
