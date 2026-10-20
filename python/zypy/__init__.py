import importlib.metadata

import zypy.backend

__version__ = importlib.metadata.version("zypy")

build_wheel = zypy.backend.build_wheel
build_editable = zypy.backend.build_editable
build_sdist = zypy.backend.build_sdist
prepare_metadata_for_build_wheel = zypy.backend.prepare_metadata_for_build_wheel
prepare_metadata_for_build_editable = zypy.backend.prepare_metadata_for_build_editable
