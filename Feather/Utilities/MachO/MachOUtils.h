//
//  MachOUtils.h
//  Feather
//
//  Created by samara on 12.06.2025.
//

@import Darwin;
@import Foundation;
@import MachO;

NSString *LCPatchMachOFixupARM64eSlice(const char *path);
NSString *LCPatchMachOForSDK26(const char *path);

// 0: no issue detected or unrecognized file, 1: encrypted ARM64, 2: no ARM64 slice.
int LCInspectIOSExecutable(const char *path);
