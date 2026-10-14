#include "OBNeural.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  if (argc != 3) { fputs("Usage: neural-tests model.mlmodelc initial-state.f32\n",stderr); return 2; }
  char error[1024] = {0};
  assert(!ob_neural_create(NULL, argv[2], error, sizeof(error)) && error[0]);
  OBNeural *p = ob_neural_create(argv[1], argv[2], error, sizeof(error));
  if (!p) { fprintf(stderr, "%s\n",error); return 3; }
  enum { Hops = 32, Count = Hops * OB_NEURAL_HOP * 2 };
  float *first = calloc(Count, sizeof(float)); assert(first);
  float hop[OB_NEURAL_HOP*2], output[OB_NEURAL_HOP*2];
  // Reset exactly reproduces the sequence; in-place and separate buffers agree.
  for (unsigned pass = 0; pass < 2; ++pass) {
    assert(ob_neural_reset(p));
    for (unsigned block = 0; block < Hops; ++block) {
      for (unsigned i = 0; i < OB_NEURAL_HOP; ++i) {
        unsigned t = block*OB_NEURAL_HOP+i;
        hop[2*i] = .05f*sinf(t*.03f)+.02f*sinf(t*.079f);
        hop[2*i+1] = 0;
      }
      float *result = pass ? output : hop;
      assert(ob_neural_process(p, hop, result));
      for (unsigned i = 0; i < OB_NEURAL_HOP*2; ++i) {
        assert(isfinite(result[i]));
        if (!pass) first[block*OB_NEURAL_HOP*2+i] = result[i];
        else assert(fabsf(result[i]-first[block*OB_NEURAL_HOP*2+i]) < 1e-7f);
        if (i%2) assert(fabsf(result[i]) < 1e-7f);
      }
    }
  }
  hop[0] = NAN; assert(!ob_neural_process(p,hop,output));
  assert(ob_neural_reset(p)); memset(hop,0,sizeof(hop));
  assert(ob_neural_process(p,hop,output));
  for (unsigned i = 0; i < OB_NEURAL_HOP*2; ++i) assert(fabsf(output[i]) < 1e-7f);
  free(first); ob_neural_destroy(p);
  puts("PASS neural reset, stereo isolation, in-place parity, silence and invalid input");
}
