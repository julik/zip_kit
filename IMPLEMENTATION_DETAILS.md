# Implementation details

The ZipKit streaming implementation is designed around the following requirements:

* Only ahead-writes (no IO seek or rewind)
* Automatic switching to Zip64 as the files get written (no IO seeks), but not requiring Zip64 support if the archive can do without
* Make use of the fact that CRC32 checksums and the sizes of the files (compressed _and_ uncompressed) are known upfront
* Make it possible to output "sparse" ZIP archives (manifests that can be resolved into a ZIP via edge includes)

It strives to be compatible with the following unzip programs _at the minimum:_

* OSX - builtin ArchiveUtility (except the Zip64 support when files larger than 4GB are in the archive)
* OSX - The Unarchiver, at least 3.10.1
* Windows 7 - built-in Explorer zip browser (except for Unicode filenames which it just doesn't support)
* Windows 7 - 7Zip 9.20

Below is the list of _specific_ decisions taken when writing the implementation, with an explanation for each.

## Data descriptors (postfix CRC32/file sizes)

Data descriptors permit you to generate "postfix" ZIP files (where you write the local file header without having to
know the CRC32 and the file size upfront, then write the compressed file data, and only then - once you know what your CRC32,
compressed and uncompressed sizes are etc. - write them into a data descriptor that follows the file data.

The streamer has optional support for data descriptors. Their use can apparently [ be problematic](https://github.com/thejoshwolfe/yazl/issues/13)
with the 7Zip version that we want to support, but in our tests everything worked fine.

For more info see https://github.com/thejoshwolfe/yazl#general-purpose-bit-flag

## Zip64 support

Zip64 support switches on _by itself_, automatically, when _any_ of the following conditions is met:

* The start of the central directory lies beyound the 4GB limit
* The ZIP archive has more than 65535 files added to it
* Any entry is present whose compressed _or_ uncompressed size is above 4GB

When writing out local file headers, the Zip64 extra field (and related changes to the standard fields) are
_only_ performed if one of the file sizes is larger than 4GB. Otherwise the Zip64 extra will _only_ be
written in the central directory entry, but not in the local file header.

This has to do with the fact that otherwise we would write Zip64 extra fields for all local file headers,
regardless whether the file actually requires Zip64 or not. That might impede some older tools from reading
the archive, which is a problem you don't want to have if your archive otherwise fits perfectly below all
the Zip64 thresholds.

To be compatible with Windows7 built-in tools, the Zip64 extra field _must_ be written as _the first_ extra
field, any other extra fields should come after.

## International filename support and the Info-ZIP extra field

If a diacritic-containing character (such as å) does fit into the DOS-437
codepage, it should be encodable as such. This would, in theory, let older Windows tools
decode the filename correctly. However, this only works under the following circumstances:

* All the filenames in the archive are within the same "super-ASCII" encoding
* The Windows locale on the computer opening the archive is set to the same locale as the filename in the archive

A better approach is to use the EFS flag, which we enable when a filename does not encode cleanly
into base ASCII. The extended filename extra field did not work well for us - and it does not
combine correctly with the EFS flag.

There are some interesting notes about the Info-ZIP/EFS combination here
https://commons.apache.org/proper/commons-compress/zip.html

## Directory support

ZIP offers the possibility to store empty directories (folders). The directories that contain files, however, get
created automatically at unarchive time.  If you store a file, called, say, `docs/item.doc` then the unarchiver will
automatically create the `docs` directory if it doesn't exist already. So you need to use the directory creation
methods only if you do not have any files in those directories.