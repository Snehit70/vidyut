from gi.repository import GObject, Nautilus
import subprocess


class VidyutSendExtension(GObject.GObject, Nautilus.MenuProvider):
    def get_file_items(self, *args):
        files = args[-1]
        paths = []
        for file_info in files:
            if file_info.is_gone() or file_info.is_directory():
                continue
            location = file_info.get_location()
            path = location.get_path() if location is not None else None
            if path:
                paths.append(path)
        if not paths:
            return []
        item = Nautilus.MenuItem(
            name="Vidyut::Send",
            label="Send with Vidyut",
        )
        item.connect("activate", self._send, paths)
        return [item]

    def _send(self, _item, paths):
        subprocess.Popen(["vidyut-send", *paths])
