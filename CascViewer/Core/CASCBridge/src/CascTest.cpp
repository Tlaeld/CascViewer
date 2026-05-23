// NOTE: This is a standalone internal test program for the CascLib submodule.
// It directly includes CascLib internal headers and is NOT part of the public
// CascBridge API. Do not use it as a reference for production code.
#include <cstdio>
#include <string>
#include <CascLib.h>
#include <CascCommon.h>

int main(int argc, const char* argv[]) {
    // Force re-download by using a non-existent path
    const char* product = (argc > 1) ? argv[1] : "s2";
    const char* region = (argc > 2) ? argv[2] : "us";
    
    std::string config = "/tmp/casc_test_empty*";
    config += product;
    config += "*";
    config += region;
    
    printf("Opening: %s\n", config.c_str());
    
    CASC_OPEN_STORAGE_ARGS args = {};
    args.Size = sizeof(CASC_OPEN_STORAGE_ARGS);
    args.dwLocaleMask = CASC_LOCALE_ALL;
    args.dwFlags = CASC_FEATURE_ALLOW_DOWNLOAD | CASC_FEATURE_ONLINE;
    
    HANDLE hStorage = NULL;
    bool result = CascOpenStorageEx(config.c_str(), &args, true, &hStorage);
    
    if (result) {
        printf("SUCCESS! Storage opened.\n");
        CascCloseStorage(hStorage);
    } else {
        DWORD error = GetCascError();
        printf("FAILED! error=%u (0x%08X)\n", error, error);
        if (error == ERROR_FILE_NOT_FOUND) printf("  -> ERROR_FILE_NOT_FOUND\n");
        if (error == ERROR_NOT_SUPPORTED) printf("  -> ERROR_NOT_SUPPORTED\n");
        if (error == 0x03) printf("  -> EAS_E_INVALID_FILE_CHECKSUM or similar\n");
    }
    
    return 0;
}
