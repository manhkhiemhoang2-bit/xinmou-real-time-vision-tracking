import sys, os
sys.path.insert(0,".")
import check_alg_top_full as C
d = C.parse(os.path.join("_mut_full","dump_top_full.txt"))
frames = 6
exp_img, exp_pack, bb = C.expected_frames(frames, None)
print("bbox=",bb)
n,b = C.check_e(d, frames, None, True)
print("E:",n,b)
