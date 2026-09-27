# End-to-end tests for the R target's carrier conversions. The packages are
# generated from the hand-authored carrier fixtures; the C library below
# implements the same layouts and entrypoints, so a reader that misreads an
# offset or a length returns the wrong value rather than crashing.

# The C library every generated carrier package in this file calls. Keep it in
# step with the `bindinginfo_*.json` fixtures each package is emitted from.
const _R_CARRIER_C = raw"""
#include <stdlib.h>
#include <string.h>
typedef struct { int code; unsigned char message[256]; } JLWStatus;
typedef struct { long dims[1]; double *data; } CVectorD;
typedef struct { long dims[3]; double *data; } CArray3;
typedef struct { long dims[2]; double *data; } CMatrix;
typedef struct { int length; unsigned char *data; } CStringB;
typedef struct { long length; unsigned char *data; } CStringO;
typedef struct { long length; CStringO *data; } CStrArrayO;
typedef struct { long length; CStringO *data; } CStrArrayB;
typedef struct { long length; CStringO *keys; double *values; } CDictO;
typedef struct { long length; CStringO *keys; double *values; } CDictB;
typedef struct { long length; CStringO *keys; int *values; } CDictIO;
typedef struct { long length; CStringO *keys; int *values; } CDictIB;
typedef struct { int has_value; double value; } COptD;
typedef struct { JLWStatus status; CStringO value; } JLWResultCS;
typedef struct { JLWStatus status; CDictO value; } JLWResultCD;
typedef struct { CVectorD x_1; long x_2; } TupleCVL;
typedef struct { CVectorD values[2]; } TupleCVV;
typedef struct { CStringO x_1; CStrArrayO x_2; CDictO x_3; COptD x_4; } TupleBundle;
typedef struct { TupleCVL values; } CNTupleCVL;
typedef struct { TupleCVV values; } CNTupleCVV;
typedef struct { TupleBundle values; } CNTupleBundle;
typedef struct { JLWStatus status; CNTupleCVL value; } JLWResultCVL;
typedef struct { JLWStatus status; CNTupleCVV value; } JLWResultCVV;
typedef struct { JLWStatus status; CNTupleBundle value; } JLWResultBundle;

static void set_status(JLWStatus *s, int code, const char *msg) {
  s->code = code; memset(s->message, 0, 256);
  if (msg) strncpy((char *)s->message, msg, 255);
}

double sum3d(CArray3 a) {
  long n = a.dims[0]*a.dims[1]*a.dims[2]; double s = 0;
  for (long i = 0; i < n; i++) s += a.data[i];
  return s;
}

double trace_cmatrix(CMatrix m) {
  double s = 0; long n = m.dims[0] < m.dims[1] ? m.dims[0] : m.dims[1];
  for (long i = 0; i < n; i++) s += m.data[i + i*m.dims[0]];
  return s;
}

int greeting_length(CStringB s) { return s.length; }

CStringB greeting(void) {
  static unsigned char b[] = "hello"; CStringB s; s.length=5; s.data=b; return s;
}

static CStringO make_owned(const char *v) {
  CStringO s; s.length=(long)strlen(v); s.data=(unsigned char*)malloc(s.length+1);
  memcpy(s.data, v, s.length+1); return s;
}

CStringO give_greeting(void) { return make_owned("hello"); }
JLWResultCS greet(void) {
  JLWResultCS r; set_status(&r.status,0,""); r.value=give_greeting(); return r;
}

long take_strs(CStrArrayB a) {
  long t=0; for (long i=0;i<a.length;i++) t+=a.data[i].length; return t;
}

CStrArrayO give_strs(void) {
  CStrArrayO a; a.length=2; a.data=(CStringO*)malloc(2*sizeof(CStringO));
  a.data[0]=make_owned("alpha"); a.data[1]=make_owned("beta"); return a;
}

static void fill_dict(CDictO *d, const char **keys, const double *vals, long n) {
  d->length=n; d->keys=(CStringO*)malloc((n>0?n:1)*sizeof(CStringO));
  d->values=(double*)malloc((n>0?n:1)*sizeof(double));
  for (long i=0;i<n;i++) { d->keys[i]=make_owned(keys[i]); d->values[i]=vals[i]; }
}

long take_dict(CDictB d) {
  long t=0; for (long i=0;i<d.length;i++) t+=d.keys[i].length; return t;
}

CDictO give_dict(void) {
  static const char *keys[] = {"a","bb"};
  static const double vals[] = {1.5, -2.0};
  CDictO d; fill_dict(&d, keys, vals, 2); return d;
}

JLWResultCD tally(void) {
  JLWResultCD r; set_status(&r.status,0,""); r.value=give_dict(); return r;
}

int take_dict_i32(CDictIB d) {
  int t=0; for (long i=0;i<d.length;i++) t += d.values[i]; return t;
}

void give_dict_i32(CDictIO *d) {
  static const char *keys[] = {"a","bb"};
  static const int vals[] = {3, 4};
  d->length=2;
  d->keys=(CStringO*)malloc(2*sizeof(CStringO));
  d->values=(int*)malloc(2*sizeof(int));
  for (long i=0;i<2;i++) { d->keys[i]=make_owned(keys[i]); d->values[i]=vals[i]; }
}

double take_opt(COptD o) { return o.has_value ? o.value : -1.0; }
COptD give_opt(void) { COptD o; o.has_value=1; o.value=3.5; return o; }

CVectorD give_vec(void) {
  CVectorD v; v.dims[0]=3; v.data=(double*)malloc(3*sizeof(double));
  v.data[0]=1; v.data[1]=2; v.data[2]=3; return v;
}

JLWResultCVL stats(void) {
  JLWResultCVL r; set_status(&r.status,0,"");
  r.value.values.x_1 = give_vec(); r.value.values.x_2 = 42; return r;
}

JLWResultCVV pair(void) {
  JLWResultCVV r; set_status(&r.status,0,"");
  r.value.values.values[0] = give_vec();
  r.value.values.values[1].dims[0]=2;
  r.value.values.values[1].data=(double*)malloc(2*sizeof(double));
  r.value.values.values[1].data[0]=9; r.value.values.values[1].data[1]=8;
  return r;
}

JLWResultBundle bundle(void) {
  JLWResultBundle r; set_status(&r.status,0,"");
  r.value.values.x_1 = make_owned("hi");
  r.value.values.x_2 = give_strs();
  r.value.values.x_3 = give_dict();
  r.value.values.x_4 = give_opt();
  return r;
}

void jlw_free(void *p) { free(p); }
void jlw_free_strings(CStringO *p, long n) {
  for (long i=0;i<n;i++) free(p[i].data);
  free(p);
}
"""

# The R driver: load each generated package into its own environment, resolve
# the entrypoints against the one compiled library, and call its façade.
# `__LIB__` and `__ROOT__` are substituted with the compiled library path and
# the directory the packages were written to. `raw` keeps the R `$` operators
# from being read as Julia interpolation.
const _R_CARRIER_SCRIPT = raw"""
library(rdyncall)
handle <- dynload("__LIB__")
root <- "__ROOT__"
load_pkg <- function(name) {
  env <- new.env(parent = globalenv())
  sys.source(file.path(root, name, "R", "lowlevel.R"), envir = env)
  assign(".jlr_handle", handle, envir = env$.jlr_syms)
  for (sym in env$.jlr_symbols) {
    assign(sym, dynsym(handle, sym), envir = env$.jlr_syms)
  }
  facade <- new.env(parent = env)
  sys.source(file.path(root, name, "R", "facade.R"), envir = facade)
  facade
}
chk <- function(label, got, want) {
  if (!identical(got, want)) {
    stop(label, ": got ", paste(capture.output(print(got)), collapse=" "),
         " want ", paste(capture.output(print(want)), collapse=" "))
  }
  cat("ok ", label, "\n")
}

a <- load_pkg("rcarray3")
chk("sum3d", a$sum3d(array(as.double(1:8), dim=c(2,2,2))), 36)

m <- load_pkg("rcmatrix")
chk("trace_cmatrix", m$trace_cmatrix(matrix(c(1,2,3,4), nrow=2)), 5)

s <- load_pkg("rcstring")
chk("greeting_length", s$greeting_length("hello"), 5L)
chk("greeting", s$greeting(), "hello")

so <- load_pkg("rcstringowned")
chk("give_greeting", so$give_greeting(), "hello")

sa <- load_pkg("rcstrarray")
chk("take_strs", sa$take_strs(c("ab","cde")), 5)
chk("give_strs", sa$give_strs(), c("alpha","beta"))

d <- load_pkg("rcdict")
chk("take_dict", d$take_dict(c(a=1.5, bb=-2)), 3)
chk("give_dict", d$give_dict(), c(a=1.5, bb=-2.0))

di <- load_pkg("rcdictint32")
chk("take_dict_i32", di$take_dict_i32(c(a=3L, bb=4L)), 7)
chk("give_dict_i32", di$give_dict_i32(), c(a=3L, bb=4L))

o <- load_pkg("rcopt")
chk("take_opt", o$take_opt(3.5), 3.5)
chk("take_opt absent", o$take_opt(NULL), -1)
chk("give_opt", o$give_opt(), 3.5)

vo <- load_pkg("rcarrayowned")
chk("give_vec", vo$give_vec(), c(1,2,3))

ct <- load_pkg("rctuple")
chk("stats", ct$stats(), list(c(1,2,3), 42))
chk("pair", ct$pair(), list(c(1,2,3), c(9,8)))
chk("bundle", ct$bundle(),
    list("hi", c("alpha","beta"), c(a=1.5, bb=-2.0), 3.5))

jo <- load_pkg("rjlwresultowned")
chk("greet", jo$greet(), "hello")
chk("tally", jo$tally(), c(a=1.5, bb=-2.0))
cat("OK\n")
"""

@testset "R carrier end-to-end" begin
    compiler = _r_compiler()
    rscript = _r_toolchain()
    if !isnothing(compiler) && !isnothing(rscript)
        packages = (
            ("bindinginfo_carray3.json", "rcarray3", "libcarray3"),
            ("bindinginfo_cmatrix.json", "rcmatrix", "libcmatrix"),
            ("bindinginfo_cstring.json", "rcstring", "libcstring"),
            (
                "bindinginfo_cstring_owned.json", "rcstringowned",
                "libcstringowned",
            ),
            ("bindinginfo_cstrarray.json", "rcstrarray", "libcstrarray"),
            ("bindinginfo_cdict.json", "rcdict", "libcdict"),
            (
                "bindinginfo_cdict_int32.json", "rcdictint32",
                "libcdictint32",
            ),
            ("bindinginfo_copt.json", "rcopt", "libcopt"),
            (
                "bindinginfo_carray_owned.json", "rcarrayowned",
                "libcarrayowned",
            ),
            ("bindinginfo_ctuple.json", "rctuple", "libctuple"),
            (
                "bindinginfo_jlwresult_owned.json", "rjlwresultowned",
                "libjlwresultowned",
            ),
        )
        mktempdir() do path
            for (fixture, pkg, lib) in packages
                write_wrapper(RTarget(path, pkg, lib), read_abi_info(fixture))
            end
            csrc = joinpath(path, "carriers.c")
            write(csrc, _R_CARRIER_C)
            lib = joinpath(path, "libcarriers." * Base.Libc.Libdl.dlext)
            compile = `$compiler -shared -fPIC -o $lib $csrc`
            ok = success(pipeline(compile; stdout = devnull, stderr = devnull))
            ok || @info "R carrier test library compile failed" command = compile
            @test ok
            if ok
                script = joinpath(path, "carriers.R")
                write(
                    script,
                    replace(
                        _R_CARRIER_SCRIPT, "__LIB__" => lib, "__ROOT__" => path
                    ),
                )
                out = IOBuffer()
                ok = success(
                    pipeline(
                        `$rscript --vanilla $script`; stdout = out, stderr = out
                    )
                )
                ok || @info "R carrier end-to-end output" output = String(take!(out))
                @test ok
            end
        end
    end
end
