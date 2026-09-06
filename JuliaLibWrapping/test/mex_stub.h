/* Minimal stand-in for MATLAB's mex.h: enough to type-check generated code. */
#ifndef JLW_MEX_STUB_H
#define JLW_MEX_STUB_H
#include <stddef.h>
#include <stdint.h>
typedef struct mxArray_tag mxArray;
typedef size_t mwSize;
typedef unsigned char mxLogical;
typedef enum { mxUNKNOWN_CLASS, mxDOUBLE_CLASS, mxSINGLE_CLASS, mxLOGICAL_CLASS,
               mxINT8_CLASS, mxUINT8_CLASS, mxINT16_CLASS, mxUINT16_CLASS,
               mxINT32_CLASS, mxUINT32_CLASS, mxINT64_CLASS, mxUINT64_CLASS } mxClassID;
typedef enum { mxREAL, mxCOMPLEX } mxComplexity;
#define mxMAXNAM 64
int mxIsSparse(const mxArray *);
int mxIsDouble(const mxArray *); int mxIsSingle(const mxArray *);
int mxIsLogical(const mxArray *); int mxIsChar(const mxArray *);
int mxIsCell(const mxArray *); int mxIsStruct(const mxArray *);
int mxIsEmpty(const mxArray *);
int mxIsInt8(const mxArray *); int mxIsUint8(const mxArray *);
int mxIsInt16(const mxArray *); int mxIsUint16(const mxArray *);
int mxIsInt32(const mxArray *); int mxIsUint32(const mxArray *);
int mxIsInt64(const mxArray *); int mxIsUint64(const mxArray *);
mwSize mxGetNumberOfElements(const mxArray *);
mwSize mxGetNumberOfDimensions(const mxArray *);
const mwSize *mxGetDimensions(const mxArray *);
double *mxGetDoubles(const mxArray *); float *mxGetSingles(const mxArray *);
mxLogical *mxGetLogicals(const mxArray *);
int8_t *mxGetInt8s(const mxArray *); uint8_t *mxGetUint8s(const mxArray *);
int16_t *mxGetInt16s(const mxArray *); uint16_t *mxGetUint16s(const mxArray *);
int32_t *mxGetInt32s(const mxArray *); uint32_t *mxGetUint32s(const mxArray *);
int64_t *mxGetInt64s(const mxArray *); uint64_t *mxGetUint64s(const mxArray *);
double mxGetScalar(const mxArray *);
char *mxArrayToUTF8String(const mxArray *);
void *mxMalloc(size_t); void mxFree(void *);
const mxArray *mxGetCell(const mxArray *, mwSize);
void mxSetCell(mxArray *, mwSize, mxArray *);
mxArray *mxCreateCellMatrix(mwSize, mwSize);
int mxGetNumberOfFields(const mxArray *);
const char *mxGetFieldNameByNumber(const mxArray *, int);
const mxArray *mxGetFieldByNumber(const mxArray *, mwSize, int);
void mxSetFieldByNumber(mxArray *, mwSize, int, mxArray *);
mxArray *mxCreateStructMatrix(mwSize, mwSize, int, const char **);
mxArray *mxCreateNumericArray(mwSize, const mwSize *, mxClassID, mxComplexity);
mxArray *mxCreateNumericMatrix(mwSize, mwSize, mxClassID, mxComplexity);
mxArray *mxCreateString(const char *);
void mxDestroyArray(mxArray *);
mxArray *mxDuplicateArray(const mxArray *);
void mexErrMsgIdAndTxt(const char *, const char *, ...);
#endif
