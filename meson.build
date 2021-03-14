project('eventcore', 'd',
    meson_version: '>=0.50',
    version: '0.9.7'
)

project_soversion      = '0'
project_version_suffix = ''
project_version        = meson.project_version()
project_version_full   = project_version + project_version_suffix

taggedalgebraic_dep = dependency('taggedalgebraic',
    version: ['>=0.10.12', '<0.12'],
    fallback: ['taggedalgebraic', 'taggedalgebraic_source_dep'])

source_root = meson.source_root()
build_root = meson.build_root()
subdir('source/eventcore')
subdir('examples')
