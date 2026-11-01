/* BugCapsule patch runtime C ABI v1. See spec/abi-v1.md. */
#ifndef BCPATCH_H
#define BCPATCH_H
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BcpEngine BcpEngine;
typedef struct { uint8_t *ptr; size_t len; } BcpBuf;

enum {
  BCP_OP_STATUS = 1, BCP_OP_STAGE = 2, BCP_OP_CHANNEL = 3, BCP_OP_KEYRING = 4,
  BCP_OP_HEALTHY = 5, BCP_OP_FAULT = 6, BCP_OP_EVAL = 7, BCP_OP_ASSET = 8,
  BCP_OP_RECEIPTS = 9, BCP_OP_ACK = 10, BCP_OP_CANCEL = 11, BCP_OP_LOCAL_EVAL = 12, BCP_OP_SURFACE = 13
};
enum { BCP_OK = 0, BCP_ERROR = 1, BCP_PANIC = 2 };

uint32_t bcp_abi_version(void);
int32_t bcp_open(const uint8_t *cfg, size_t cfg_len, BcpEngine **out_engine, BcpBuf *out);
int32_t bcp_call(const BcpEngine *engine, uint32_t op, const uint8_t *a, size_t a_len,
                 const uint8_t *b, size_t b_len, uint64_t n, BcpBuf *out);
void bcp_buf_free(BcpBuf buf);
void bcp_close(BcpEngine *engine);

#ifdef __cplusplus
}
#endif
#endif
