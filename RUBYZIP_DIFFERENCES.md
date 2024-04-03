# Key differences between Rubyzip and ZipKit

Please bear in mind that this is written down not to disparage [Rubyzip.](https://github.com/rubyzip/rubyzip)

Rubyzip is, by all means, a very mature, fully featured library, and while ZipKit does have overlap with it in some functionality there are
differences in supported features which may be important for you when choosing.

## What ZipKit supports and Rubyzip does not

* ZipKit outputs archives in a streaming fashion, using data descriptors.
  This allows output of archives of very large size, without buffering.
  Rubyzip will seek in the already written archive to overwrite the local entry after the write of every file into the output ZIP.
  At the moment, it is difficult to build a streaming Rubyzip solution due to the output of extra field placeholders.
* ZipKit supports block-deflate which allows for distributed compression of files
* ZipKit reads files from the central directory, which allows for very rapid reading. Reading works well with data descriptors
  and Zip64, and is economical enough to enable "remote uncapping" where pieces of a ZIP file get read over HTTP to reconstruct
  the archive structure. Actual reading can then be done on a per-entry basis. Rubyzip reads entry data from local entries, which
  is error prone and much less economical than using the central directory
* When writing, ZipKit applies careful buffering to speed up CRC32 calculations. Rubyzip combines CRC32 values at every write, which
  can be slow if there are many small writes.
* ZipKit comes with a Rails helper and a Rack-compatible response body for facilitating streaming. Rubyzip has no Rails integration
  and no Rack integration.
* ZipKit allows you to estimate the exact size of an archive ahead of time
* ZipKit has a heuristic module which picks the storage mode (stored or deflated) depending on how well your input compresses
* ZipKit requires components using autoloading, which means that your application will likely boot faster as you will almost never
  need all of the features in one codebase. Rubyzip requires its components eagerly.
* ZipKit comes with exhaustive YARD documentation and `.rbi` typedefs for [Sorbet/Tapioca](https://sorbet.org/blog/2022/07/27/srb-tapioca)
* ZipKit allows you to compose "sparse" ZIP files where the contents of the files inside the archive comes from an external source, and does not have to be passed through the library (or be turned into Ruby strings), which enables interesting use cases such as download proxies with random access and resume.

## What Rubyzip supports and ZipKit does not

* Rubyzip allows limited manipulation of existing ZIP files by overwriting the archive entries
* Rubyzip supports "classic" ZIP encryption - both for reading and writing. ZipKit has no encryption support.
* Rubyzip allows extraction into a directory, ZipKit avoids implementing this for security reasons
* Rubyzip allows archiving a directory, ZipKit avoids implementing this for security reasons
* Rubyzip supports separate atime and ctime in the `UniversalTime` extra fields. ZipKit outputs just one timestamp
* Rubyzip attempts to faithfully replicate UNIX permissions on the files being output. ZipKit does not attempt that
  because it turned out that these permissions can break unarchiving of folders on macOS.

## Where there is currently feature parity

These used to be different, but Rubyzip has made great progress in addressing.

* ZipKit automatically applies the EFS flag for Unicode filenames in the archive. This used to be optional in RubyZip
* ZipKit automatically enables Zip64 and does so only when necessary. applies the EFS flag for Unicode filenames in the archive. This used to be optional in RubyZip.
* ZipKit outputs the `UT` precise time extra field
* ZipKit used to be distributed under the MIT-Hippocratic license which is much more restrictive than the Rubyzip BSD-2-Clause. ZipKit is now MIT-licensed. 

## Code style differences

Rubyzip is written in a somewhat Java-like style, with a lot of encapsulation and data hiding. ZipKit aims to be more approachable and have "less" of everything.
Less modules, less classes, less OOP - just enough to be useful. But that is a matter of taste, and as such should not matter to you all that much
when picking one over the other. Or it might, you never know ;-)
