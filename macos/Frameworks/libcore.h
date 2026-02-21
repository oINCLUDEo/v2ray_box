// libcore.h - C bindings for hiddify-core dylib
// Generated for hiddify-core v4.0.4 macOS

#ifndef LIBCORE_H
#define LIBCORE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Setup modes
typedef enum {
    SETUP_MODE_NONE = 0,    // Standalone mode
    SETUP_MODE_GRPC = 1,    // gRPC server mode
    SETUP_MODE_PROXY = 2    // Proxy mode
} SetupMode;

// Setup the core with directories and configuration
// Parameters:
//   baseDir - Base directory for data storage
//   workingDir - Working directory
//   tempDir - Temporary directory
//   mode - Setup mode (0=none, 1=grpc, 2=proxy)
//   listen - Listen address for gRPC server (empty string if not used)
//   secret - Secret for gRPC authentication (empty string if not used)
//   statusPort - Port for status updates (0 = disabled)
//   debug - Enable debug mode
// Returns empty string on success, error message on failure
extern char* setup(const char* baseDir, const char* workingDir, const char* tempDir, 
                   int mode, const char* listen, const char* secret, 
                   int64_t statusPort, uint8_t debug);

// Start the proxy/VPN service with config path
// Parameters:
//   configPath - Path to the configuration file
//   disableMemoryLimit - Whether to disable memory limit
// Returns empty string on success, error message on failure
extern char* start(const char* configPath, uint8_t disableMemoryLimit);

// Stop the proxy/VPN service
// Returns empty string on success, error message on failure
extern char* stop(void);

// Restart the proxy/VPN service with new config
// Parameters:
//   configPath - Path to the configuration file
//   disableMemoryLimit - Whether to disable memory limit
// Returns empty string on success, error message on failure
extern char* restart(const char* configPath, uint8_t disableMemoryLimit);

// Parse CLI arguments
extern char* parseCli(int argc, char** argv);

// Cleanup resources
extern void cleanup(void);

// Free a string allocated by the library
extern void freeString(char* str);

// Get the gRPC server's public key
extern char* GetServerPublicKey(void);

// Add a client's public key for gRPC authentication
extern char* AddGrpcClientPublicKey(const char* clientPublicKey);

// Close gRPC server
extern void closeGrpc(int mode);

// Start the core gRPC server (if using gRPC mode)
extern char* StartCoreGrpcServer(const char* listenAddress);

#ifdef __cplusplus
}
#endif

#endif // LIBCORE_H
