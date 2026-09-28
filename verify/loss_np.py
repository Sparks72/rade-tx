"""
Numpy port of radae's loss.py (distortion_loss + alignment search), so the C and
WebAssembly builds can be held to RADE's own pass/fail thresholds without
installing PyTorch. Same arithmetic, same broadcasting, same search.
"""
import sys, argparse
import numpy as np

NB_TOTAL, NUSED, TSTEP = 36, 20, 0.01

def load(fn):
    f = np.fromfile(fn, dtype=np.float32).reshape(1, -1, NB_TOTAL)
    return f[:, :, :NUSED].astype(np.float64)

def distortion_loss(y_true, y_pred):
    # radae/radae_base.py distortion_loss, 20-feature case (no data column)
    ceps_error  = y_pred[..., :18] - y_true[..., :18]
    pitch_error = 2 * (y_pred[..., 18:19] - y_true[..., 18:19])
    corr_error  = y_pred[..., 19:20] - y_true[..., 19:20]
    pitch_weight = np.maximum(y_true[..., 19:20] + 0.5, 0) ** 2
    loss = np.mean(ceps_error ** 2
                   + 3. * (10 / 18) * np.abs(pitch_error) * pitch_weight
                   + (1 / 18) * corr_error ** 2, axis=-1)      # per frame
    return np.mean(loss, axis=-1)                             # over time

def find_loss(fin, fhat, clip_start, clip_end):
    x = load(fin)
    pad = np.zeros((1, int(1.0 / TSTEP), NUSED))
    x = np.concatenate([pad, x, pad], axis=1)
    y = load(fhat)
    y = y[:, clip_start:y.shape[1] - clip_end, :]
    nx, ny = x.shape[1], y.shape[1]
    assert ny and ny < nx, (ny, nx)
    best = distortion_loss(x[:, :ny, :], y)[0]; best_start = 0
    for s in range(nx - ny):
        l = distortion_loss(x[:, s:s + ny, :], y)[0]
        if l < best: best, best_start = l, s
    return best, best_start * TSTEP - 1.0, best_start

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('features'); p.add_argument('features_hat')
    p.add_argument('--loss_test', type=float, default=0.0)
    p.add_argument('--acq_time_test', type=float, default=0.0)
    p.add_argument('--clip_start', type=int, default=0)
    p.add_argument('--clip_end', type=int, default=0)
    a = p.parse_args()

    loss, acq, start = find_loss(a.features, a.features_hat, a.clip_start, a.clip_end)
    print(f"  loss: {loss:5.3f} start: {start:d} acq_time: {acq:5.2f} s")
    ok = True
    if a.loss_test > 0 and loss > a.loss_test: ok = False
    if a.acq_time_test > 0 and acq > a.acq_time_test: ok = False
    if a.loss_test > 0 or a.acq_time_test > 0:
        print("PASS" if ok else "FAIL")
        sys.exit(0 if ok else 1)
