// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ISignatureTransfer
/// @notice Minimal subset of Uniswap Permit2's SignatureTransfer interface used by the Router.
///         Canonical Permit2 lives at 0x000000000022D473030F116dDEE9F6B43aC78BA3 on every chain.
/// @dev    Vendored instead of imported because Permit2's sources pin solc 0.8.17.
interface ISignatureTransfer {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;
}
