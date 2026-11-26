//
//  MachOUtils.m
//  Feather
//
//  Created by samara on 12.06.2025.
//

#import "MachOUtils.h"

#define SDK_VERSION_26_0_0 0x1A0000

/// https://github.com/LiveContainer/LiveContainer/commit/3a029b6bb36c11cc05784a8840d41c7e46af1540
/// this is licensed under Apache-2.0, bundled when compiled.
NSString *LCPatchMachOFixupARM64eSlice(const char *path) {
	int fd = open(path, O_RDWR, 0600);
	if(fd < 0) {
		return [NSString stringWithFormat:@"Failed to open %s: %s", path, strerror(errno)];
	}
	struct stat s = {0};
	fstat(fd, &s);
	void *map = mmap(NULL, s.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if(map == MAP_FAILED) {
		close(fd);
		return [NSString stringWithFormat:@"Failed to map %s: %s", path, strerror(errno)];
	}
	
	uint32_t magic = *(uint32_t *)map;
	if(magic == FAT_CIGAM) {
		// Find arm64e slice without CPU_SUBTYPE_LIB64
		struct fat_header *header = (struct fat_header *)map;
		struct fat_arch *arch = (struct fat_arch *)(map + sizeof(struct fat_header));
		for(int i = 0; i < OSSwapInt32(header->nfat_arch); i++) {
			if(OSSwapInt32(arch->cputype) == CPU_TYPE_ARM64 && OSSwapInt32(arch->cpusubtype) == CPU_SUBTYPE_ARM64E) {
				struct mach_header_64 *header = (struct mach_header_64 *)(map + OSSwapInt32(arch->offset));
				header->cpusubtype |= CPU_SUBTYPE_LIB64;
				arch->cpusubtype = htonl(header->cpusubtype);
				break;
			}
			arch = (struct fat_arch *)((void *)arch + sizeof(struct fat_arch));
		}
	}
	
	msync(map, s.st_size, MS_SYNC);
	munmap(map, s.st_size);
	close(fd);
	return nil;
}

static NSString *PatchMachOAtOffset(void *mapped, size_t fileSize, off_t offset, uint32_t index) {
	uint8_t *base = (uint8_t *)mapped + offset;
	
	if ((size_t)(offset + sizeof(struct mach_header_64)) > fileSize) {
		return [NSString stringWithFormat:@"Slice %u: Invalid offset or truncated header", index];
	}
	
	struct mach_header_64 *header = (struct mach_header_64 *)base;
	if (header->magic != MH_MAGIC_64) {
		return [NSString stringWithFormat:@"Slice %u: Unsupported or non-64-bit Mach-O", index];
	}
	
	struct load_command *cmd = (struct load_command *)(base + sizeof(struct mach_header_64));
	
	for (uint32_t i = 0; i < header->ncmds; i++) {
		uint8_t *cmdEnd = (uint8_t *)cmd + sizeof(struct load_command);
		if ((size_t)(cmdEnd - (uint8_t *)mapped) > fileSize) {
			return [NSString stringWithFormat:@"Slice %u: Load command exceeds file size", index];
		}
		
		if (cmd->cmd == LC_BUILD_VERSION) {
			struct build_version_command *bvc = (struct build_version_command *)cmd;
			bvc->sdk = SDK_VERSION_26_0_0;
			return [NSString stringWithFormat:@"Slice %u: Patched LC_BUILD_VERSION to SDK 26.0", index];
		}
		
		cmd = (struct load_command *)((uint8_t *)cmd + cmd->cmdsize);
	}
	
	return [NSString stringWithFormat:@"Slice %u: LC_BUILD_VERSION not found", index];
}

NSString *LCPatchMachOForSDK26(const char *path) {
	int fd = open(path, O_RDWR, 0600);
	if(fd < 0) {
		return [NSString stringWithFormat:@"Failed to open %s: %s", path, strerror(errno)];
	}
	struct stat s = {0};
	fstat(fd, &s);
	void *map = mmap(NULL, s.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if(map == MAP_FAILED) {
		close(fd);
		return [NSString stringWithFormat:@"Failed to map %s: %s", path, strerror(errno)];
	}
	
	NSMutableString *result = [NSMutableString string];
	uint32_t magic = *(uint32_t *)map;
	
	if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
		struct fat_header *fat = (struct fat_header *)map;
		uint32_t nfat = OSSwapBigToHostInt32(fat->nfat_arch);
		struct fat_arch *archs = (struct fat_arch *)((uint8_t *)map + sizeof(struct fat_header));
		
		for (uint32_t i = 0; i < nfat; i++) {
			uint32_t offset = OSSwapBigToHostInt32(archs[i].offset);
			NSString *sliceResult = PatchMachOAtOffset(map, s.st_size, offset, i);
			[result appendFormat:@"%@\n", sliceResult];
		}
	} else if (magic == MH_MAGIC_64) {
		NSString *mainResult = PatchMachOAtOffset(map, s.st_size, 0, 0);
		[result appendFormat:@"%@\n", mainResult];
	} else {
		munmap(map, s.st_size);
		close(fd);
		return [NSString stringWithFormat:@"Unsupported binary format %s: %s", path, strerror(errno)];
	}
	
	munmap(map, s.st_size);
	close(fd);
	return result;
}

static int InspectIOSSlice(const uint8_t *bytes, size_t size) {
	struct mach_header_64 header;
	if (size < sizeof(uint32_t)) return 0;
	uint32_t magic;
	memcpy(&magic, bytes, sizeof(magic));
	if (magic == MH_MAGIC || magic == MH_CIGAM || magic == MH_CIGAM_64) return 2;
	if (magic != MH_MAGIC_64 || size < sizeof(header)) return 0;
	memcpy(&header, bytes, sizeof(header));
	if (header.cputype != CPU_TYPE_ARM64) return 2;

	size_t cursor = sizeof(header);
	if (header.sizeofcmds > size - cursor) return 0;
	size_t end = cursor + header.sizeofcmds;
	for (uint32_t i = 0; i < header.ncmds; i++) {
		struct load_command command;
		if (end - cursor < sizeof(command)) return 0;
		memcpy(&command, bytes + cursor, sizeof(command));
		if (command.cmdsize < sizeof(command) || command.cmdsize > end - cursor) return 0;
		if (command.cmd == LC_ENCRYPTION_INFO || command.cmd == LC_ENCRYPTION_INFO_64) {
			struct encryption_info_command encryption;
			if (command.cmdsize < sizeof(encryption)) return 0;
			memcpy(&encryption, bytes + cursor, sizeof(encryption));
			if (encryption.cryptid != 0) return 1;
		}
		cursor += command.cmdsize;
	}
	return 0;
}

int LCInspectIOSExecutable(const char *path) {
	NSData *data = [NSData dataWithContentsOfFile:@(path) options:NSDataReadingMappedIfSafe error:NULL];
	const uint8_t *bytes = data.bytes;
	size_t size = data.length;
	uint32_t magic;
	if (size < sizeof(magic)) return 0;
	memcpy(&magic, bytes, sizeof(magic));
	magic = OSSwapBigToHostInt32(magic);
	if (magic != FAT_MAGIC && magic != FAT_MAGIC_64) return InspectIOSSlice(bytes, size);

	struct fat_header header;
	if (size < sizeof(header)) return 0;
	memcpy(&header, bytes, sizeof(header));
	uint32_t count = OSSwapBigToHostInt32(header.nfat_arch);
	size_t stride = magic == FAT_MAGIC_64 ? sizeof(struct fat_arch_64) : sizeof(struct fat_arch);
	if (count == 0 || count > (size - sizeof(header)) / stride) return 0;

	bool foundARM64 = false;
	for (uint32_t i = 0; i < count; i++) {
		const uint8_t *entry = bytes + sizeof(header) + i * stride;
		uint32_t cpu;
		memcpy(&cpu, entry, sizeof(cpu));
		if (OSSwapBigToHostInt32(cpu) != CPU_TYPE_ARM64) continue;

		foundARM64 = true;
		uint64_t offset, length;
		if (magic == FAT_MAGIC_64) {
			struct fat_arch_64 arch;
			memcpy(&arch, entry, sizeof(arch));
			offset = OSSwapBigToHostInt64(arch.offset);
			length = OSSwapBigToHostInt64(arch.size);
		} else {
			struct fat_arch arch;
			memcpy(&arch, entry, sizeof(arch));
			offset = OSSwapBigToHostInt32(arch.offset);
			length = OSSwapBigToHostInt32(arch.size);
		}
		if (offset <= size && length <= size - offset && InspectIOSSlice(bytes + offset, (size_t)length) == 1) return 1;
	}
	return foundARM64 ? 0 : 2;
}
