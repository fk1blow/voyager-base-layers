"""Fake cython-hidapi backed by fw_model.BOARD.
Put this directory first on sys.path and set VOYAGER_BACKEND=hidapi."""
import fw_model


def enumerate(vid, pid):
    return [{"usage_page": 0x0001, "path": b"kbd"}, {"usage_page": 0xFF60, "path": b"raw"}]


class device:
    def open_path(self, path):
        assert path == b"raw"

    def write(self, data):
        assert data[0] == 0 and len(data) == 33, data
        fw_model.BOARD.rx(data[1], data[2:])
        return len(data)

    def read(self, n, timeout_ms):
        board = fw_model.BOARD
        if not board.out and getattr(board, "later", None):
            board.later.pop(0)(board)          # simulate something happening now
        return board.out.popleft() if board.out else []

    def close(self):
        pass
