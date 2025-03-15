// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;


// inspired from the @solady ------ A different implementation of Ownable2Step

abstract contract SuperAdmin2Step {
    /*                       CUSTOM ERRORS                        */

    /// @dev The caller is not authorized to call the function.
    error SuperAdmin2Step_Unauthorized();

    /// @dev The `pendingSuperAdmin` does not have a valid handover request.
    error SuperAdmin2Step_NoHandoverRequest();

    /// @dev Cannot double-initialize.
    error SuperAdmin2Step_NewAdminIsZeroAddress();
    /*                           EVENTS                           */

    /// @dev The superAdminship is transferred from `oldSuperAdmin` to `newSuperAdmin`.

    event SuperAdminshipTransferred(address indexed oldSuperAdmin, address indexed newSuperAdmin);

    /// @dev An superAdminship handover to `pendingSuperAdmin` has been requested.
    event SuperAdminshipHandoverRequested(address indexed pendingSuperAdmin);

    /// @dev The superAdminship handover to `pendingSuperAdmin` has been canceled.
    event SuperAdminshipHandoverCanceled(address indexed pendingSuperAdmin);

    // /*                          STORAGE                           */

    /// @dev The superAdmin slot is given by:

    /// @dev keccak256("Hashstack._SUPERADMIN_SLOT")
    bytes32 internal constant _SUPERADMIN_SLOT = 0x728a99fd4f405dacd9be416f0ab5362a3b8a45ae01e04e4531610f3b47f0f332;
    /// @dev keccak256("Hashstack.superAdmin._PENDINGSUPERADMIN_SLOT")
    bytes32 internal constant _PENDINGSUPERADMIN_SLOT =
        0xd6dfe080f721daab5530894dccfcc2993346c67103e2bcc8748bf87935f5b4d9;
    /// @dev keccak256("Hashstack.superAdmin._HANDOVERTIME_SUPERADMINSLOT_SEED")
    bytes32 internal constant _HANDOVERTIME_SUPERADMINSLOT_SEED =
        0x6550ab69b2fd0d6b77d1a3569484949e74afb818f9de20661d5d5d6082bcd5de;

    /*                     INTERNAL FUNCTIONS                     */

    /// @dev Sets the superAdmin directly without authorization guard.
    function _setSuperAdmin(address _newSuperAdmin) internal virtual {
        assembly {
            if eq(_newSuperAdmin, 0) {
                // Load pre-defined error selector for zero address
                mstore(0x00, 0x4869eb34) // NewSuperAdminIsZeroAddress error
                revert(0x1c, 0x04)
            }
            /// @dev `keccak256(bytes("SuperAdminshipTransferred(address,address)"))
            log3(
                0,
                0,
                0x04d129ae6ee1a7d168abd097a088e4f07a0292c23aefc0e49b5603d029b8543f,
                sload(_SUPERADMIN_SLOT),
                _newSuperAdmin
            )
            sstore(_SUPERADMIN_SLOT, _newSuperAdmin)
        }
    }

    /*                     PUBLIC FUNCTIONS                     */

    /// @dev Throws if the sender is not the superAdmin.
    function _checkSuperAdmin() internal view virtual {
        /// @solidity memory-safe-assembly
        assembly {
            // If the caller is not the stored superAdmin, revert.
            if iszero(eq(caller(), sload(_SUPERADMIN_SLOT))) {
                mstore(0x00, 0x591f9739) // `SuperAdmin2Step_Unauthorized()`.
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev Returns how long a two-step superAdminship handover is valid for in seconds.
    /// Override to return a different value if needed.
    /// Made internal to conserve bytecode. Wrap it in a public function if needed.
    function _superAdminHandoverValidFor() internal view virtual returns (uint64) {
        return 3 * 86400;
    }
    /*                  PUBLIC UPDATE FUNCTIONS                   */

    /// @dev Request a two-step superAdminship handover to the caller.
    /// The request will automatically expire in 72 hoursby default.
    function requestSuperAdminTransfer(address _pendingOwner) public virtual onlySuperAdmin {
        unchecked {
            uint256 expires = block.timestamp + _superAdminHandoverValidFor();
            /// @solidity memory-safe-assembly
            assembly {
                sstore(_PENDINGSUPERADMIN_SLOT, _pendingOwner)
                sstore(_HANDOVERTIME_SUPERADMINSLOT_SEED, expires)
                // Emit the {SuperAdminshipHandoverRequested} event.
                log2(0, 0, 0xa391cf6317e44c1bf84ce787a20d5a7193fa44caff9e68b0597edf3cabd29fb7, _pendingOwner)
            }
        }
    }

    /// @dev Cancels the two-step superAdminship handover to the caller, if any.
    function cancelSuperAdminTransfer() public virtual onlySuperAdmin {
        /// @solidity memory-safe-assembly
        assembly {
            // Compute and set the handover slot to 0.
            sstore(_PENDINGSUPERADMIN_SLOT, 0x0)
            sstore(_HANDOVERTIME_SUPERADMINSLOT_SEED, 0x0)
            // Emit the {SuperAdminshipHandoverCanceled} event.
            log2(0, 0, 0x1570624318df302ecdd05ea20a0f8b0f8931a0cb8f4f1f8e07221e636988aa7b, caller())
        }
    }

    /// @dev Allows the superAdmin to complete the two-step superAdminship handover to `pendingSuperAdmin`.
    /// Reverts if there is no existing superAdminship handover requested by `pendingSuperAdmin`.
    function acceptSuperAdminTransfer() public virtual {
        /// @solidity memory-safe-assembly

        address pendingAdmin;
        assembly {
            pendingAdmin := sload(_PENDINGSUPERADMIN_SLOT)

            // Check that the sender is the pending admin
            if iszero(eq(caller(), pendingAdmin)) {
                mstore(0x00, 0x591f9739) // Unauthorized error
                revert(0x1c, 0x04)
            }
            // If the handover does not exist, or has expired.
            if gt(timestamp(), sload(_HANDOVERTIME_SUPERADMINSLOT_SEED)) {
                mstore(0x00, 0x12c74381) // `SuperAdmin2Step_NoHandoverRequest()`.
                revert(0x1c, 0x04)
            }
            // Set the handover slot to 0.
            sstore(_HANDOVERTIME_SUPERADMINSLOT_SEED, 0)
            sstore(_PENDINGSUPERADMIN_SLOT, 0)
        }
        _setSuperAdmin(pendingAdmin);
    }
    /*                   PUBLIC READ FUNCTIONS                    */

    /// @dev Returns the superAdmin of the contract.
    function superAdmin() public view virtual returns (address result) {
        /// @solidity memory-safe-assembly
        assembly {
            result := sload(_SUPERADMIN_SLOT)
        }
    }

    /// @dev Returns the expiry timestamp for the two-step superAdminship handover to `pendingSuperAdmin`.
    function superAdminHandoverExpiresAt() public view virtual returns (uint256 result) {
        /// @solidity memory-safe-assembly
        assembly {
            // Load the handover slot.
            result := sload(keccak256(0x0c, 0x20))
        }
    }
    /*                         MODIFIERS                          */

    /// @dev Marks a function as only callable by the superAdmin.
    modifier onlySuperAdmin() virtual {
        _checkSuperAdmin();
        _;
    }
}
