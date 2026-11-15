# Third-party notices

`libjupynvim`, the library that Neovim loads into its own process
(`core/target/release/libjupynvim.*`, and the `libjupynvim-<target>.*` files of a
release), contains the Rust crates listed below, compiled in, and the KaTeX math
fonts, embedded unmodified. This file names each one with its version, its
license as the crate states it and the copyright lines of its license files, and
then gives the full text of every license named here, once.

The crates are the ones `cargo tree -p libjupynvim -e normal` lists for the
committed `core/Cargo.lock`; the list is the same for all four release targets
(macOS arm64 and x86_64, Linux x86_64 and arm64). A license written as
`A OR B` is the crate's offer of a choice; every license offered is listed, and
its text is below. `(A OR B) AND C` means both parts apply.

This file covers `libjupynvim` only. jupynvim itself is under the MIT license (see
`LICENSE`).

## Crates compiled into libjupynvim

### adler2 2.0.1

- License: 0BSD OR MIT OR Apache-2.0
- Copyright (C) Jonas Schievink <jonasschievink@gmail.com>
- Source: <https://github.com/oyvindln/adler2>

### aho-corasick 1.1.4

- License: Unlicense OR MIT
- Copyright (c) 2015 Andrew Gallant
- Source: <https://github.com/BurntSushi/aho-corasick>

### arrayref 0.3.9

- License: BSD-2-Clause
- Copyright (c) 2015 David Roundy <roundyd@physics.oregonstate.edu>
- Source: <https://github.com/droundy/arrayref>

### arrayvec 0.7.8

- License: MIT OR Apache-2.0
- Copyright (c) Ulrik Sverdrup "bluss" 2015-2023
- Source: <https://github.com/bluss/arrayvec>

### bit-set 0.8.0

- License: Apache-2.0 OR MIT
- Copyright (c) 2023 The Rust Project Developers
- Source: <https://github.com/contain-rs/bit-set>

### bit-vec 0.8.0

- License: Apache-2.0 OR MIT
- Copyright (c) 2023 The Rust Project Developers
- Source: <https://github.com/contain-rs/bit-vec>

### bitflags 2.11.1

- License: MIT OR Apache-2.0
- Copyright (c) 2014 The Rust Project Developers
- Source: <https://github.com/bitflags/bitflags>

### bytemuck 1.25.2

- License: Zlib OR Apache-2.0 OR MIT
- Copyright (c) 2019 Daniel "Lokathor" Gee.
- Source: <https://github.com/Lokathor/bytemuck>

### cfg-if 1.0.4

- License: MIT OR Apache-2.0
- Copyright (c) 2014 Alex Crichton
- Source: <https://github.com/rust-lang/cfg-if>

### crc32fast 1.5.5

- License: MIT OR Apache-2.0
- Copyright (c) 2018 Sam Rijs, Alex Crichton and contributors
- Source: <https://github.com/srijs/rust-crc32fast>

### fancy-regex 0.14.0

- License: MIT
- Copyright 2015 The Fancy Regex Authors.
- Its AUTHORS file lists Google LLC, Raph Levien, Robin Stocker, Keith Hall and Jon Perry.
- Source: <https://github.com/fancy-regex/fancy-regex>

### fdeflate 0.3.7

- License: MIT OR Apache-2.0
- Its license files name no copyright holder. Its Cargo.toml lists the authors: The image-rs Developers.
- Source: <https://github.com/image-rs/fdeflate>

### flate2 1.1.11

- License: MIT OR Apache-2.0
- Copyright (c) 2014-2026 Alex Crichton
- Source: <https://github.com/rust-lang/flate2-rs>

### itoa 1.0.18

- License: MIT OR Apache-2.0
- Its license files name no copyright holder. Its Cargo.toml lists the authors: David Tolnay <dtolnay@gmail.com>.
- Source: <https://github.com/dtolnay/itoa>

### libc 0.2.186

- License: MIT OR Apache-2.0
- Copyright (c) The Rust Project Developers
- Source: <https://github.com/rust-lang/libc>

### log 0.4.29

- License: MIT OR Apache-2.0
- Copyright (c) 2014 The Rust Project Developers
- Source: <https://github.com/rust-lang/log>

### memchr 2.8.0

- License: Unlicense OR MIT
- Copyright (c) 2015 Andrew Gallant
- Source: <https://github.com/BurntSushi/memchr>

### miniz_oxide 0.8.9

- License: MIT OR Zlib OR Apache-2.0
- Copyright lines:
  - Copyright 2013-2014 RAD Game Tools and Valve Software
  - Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC
  - Copyright (c) 2017 Frommi
  - Copyright (c) 2017-2024 oyvindln
  - Copyright (c) 2020 Frommi
- Source: <https://github.com/Frommi/miniz_oxide/tree/master/miniz_oxide>

### miniz_oxide 0.9.1

- License: MIT OR Zlib OR Apache-2.0
- Copyright lines:
  - Copyright 2013-2014 RAD Game Tools and Valve Software
  - Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC
  - Copyright (c) 2017 Frommi
  - Copyright (c) 2017-2024 oyvindln
  - Copyright (c) 2020 Frommi
- Source: <https://github.com/Frommi/miniz_oxide/tree/master/miniz_oxide>

### phf 0.11.3

- License: MIT
- Copyright (c) 2014-2022 Steven Fackler, Yuki Okushi
- Source: <https://github.com/rust-phf/rust-phf>

### phf_shared 0.11.3

- License: MIT
- Copyright (c) 2014-2022 Steven Fackler, Yuki Okushi
- Source: <https://github.com/rust-phf/rust-phf>

### png 0.18.1

- License: MIT OR Apache-2.0
- Copyright (c) 2015 nwin
- Source: <https://github.com/image-rs/image-png>

### ratex-font 0.1.15

- License: MIT
- The crate ships no license file and names no copyright holder or author. Its Cargo.toml gives the license as MIT.
- Its source says its font metrics and symbol tables are generated from KaTeX's (`fontMetricsData.js`, `symbols.ts`).
- Source: <https://github.com/erweixin/RaTeX>

### ratex-layout 0.1.15

- License: MIT
- The crate ships no license file and names no copyright holder or author. Its Cargo.toml gives the license as MIT.
- Source: <https://github.com/erweixin/RaTeX>

### ratex-lexer 0.1.15

- License: MIT
- The crate ships no license file and names no copyright holder or author. Its Cargo.toml gives the license as MIT.
- Source: <https://github.com/erweixin/RaTeX>

### ratex-parser 0.1.15

- License: MIT
- The crate ships no license file and names no copyright holder or author. Its Cargo.toml gives the license as MIT.
- Its source says its `\ce` and `\pu` support is a Rust port of KaTeX's mhchem 3.3.0.
- Source: <https://github.com/erweixin/RaTeX>

### ratex-types 0.1.15

- License: MIT
- The crate ships no license file and names no copyright holder or author. Its Cargo.toml gives the license as MIT.
- Source: <https://github.com/erweixin/RaTeX>

### regex 1.12.3

- License: MIT OR Apache-2.0
- Copyright (c) 2014 The Rust Project Developers
- Source: <https://github.com/rust-lang/regex>

### regex-automata 0.4.14

- License: MIT OR Apache-2.0
- Copyright (c) 2014 The Rust Project Developers
- Source: <https://github.com/rust-lang/regex>

### regex-lite 0.1.9

- License: MIT OR Apache-2.0
- Copyright (c) 2014 The Rust Project Developers
- Source: <https://github.com/rust-lang/regex>

### regex-syntax 0.8.10

- License: MIT OR Apache-2.0
- Copyright (c) 2014 The Rust Project Developers
- Source: <https://github.com/rust-lang/regex>

### serde 1.0.228

- License: MIT OR Apache-2.0
- Its license files name no copyright holder. Its Cargo.toml lists the authors: Erick Tryzelaar <erick.tryzelaar@gmail.com>, David Tolnay <dtolnay@gmail.com>.
- Source: <https://github.com/serde-rs/serde>

### serde_core 1.0.228

- License: MIT OR Apache-2.0
- Its license files name no copyright holder. Its Cargo.toml lists the authors: Erick Tryzelaar <erick.tryzelaar@gmail.com>, David Tolnay <dtolnay@gmail.com>.
- Source: <https://github.com/serde-rs/serde>

### serde_json 1.0.149

- License: MIT OR Apache-2.0
- Its license files name no copyright holder. Its Cargo.toml lists the authors: Erick Tryzelaar <erick.tryzelaar@gmail.com>, David Tolnay <dtolnay@gmail.com>.
- Source: <https://github.com/serde-rs/json>

### simd-adler32 0.3.10

- License: MIT
- Copyright (c) [2021] [Marvin Countryman]
- Source: <https://github.com/mcountryman/simd-adler32>

### siphasher 1.0.4

- License: MIT OR Apache-2.0
- Copyright lines:
  - Copyright 2012-2016 The Rust Project Developers.
  - Copyright 2016-2026 Frank Denis.
- Source: <https://github.com/jedisct1/rust-siphash>

### strict-num 0.1.1

- License: MIT
- Copyright (c) 2022 Yevhenii Reizner
- Source: <https://github.com/RazrFalcon/strict-num>

### thiserror 1.0.69

- License: MIT OR Apache-2.0
- Its license files name no copyright holder. Its Cargo.toml lists the authors: David Tolnay <dtolnay@gmail.com>.
- Source: <https://github.com/dtolnay/thiserror>

### tiny-skia 0.12.0

- License: BSD-3-Clause
- Copyright lines:
  - Copyright (c) 2011 Google Inc. All rights reserved.
  - Copyright (c) 2020 Yevhenii Reizner All rights reserved.
- Source: <https://github.com/linebender/tiny-skia>

### tiny-skia-path 0.12.0

- License: BSD-3-Clause
- Copyright lines:
  - Copyright (c) 2011 Google Inc. All rights reserved.
  - Copyright (c) 2020 Yevhenii Reizner All rights reserved.
- Source: <https://github.com/linebender/tiny-skia/tree/master/path>

### tinyvec 1.13.3

- License: Zlib OR Apache-2.0 OR MIT
- Copyright (c) 2019 Daniel "Lokathor" Gee.
- Source: <https://github.com/Lokathor/tinyvec>

### ttf-parser 0.25.1

- License: MIT OR Apache-2.0
- Copyright (c) 2018 Yevhenii Reizner
- Source: <https://github.com/harfbuzz/ttf-parser>

### unicode-normalization 0.1.26

- License: (MIT OR Apache-2.0) AND Unicode-3.0
- Copyright lines:
  - Copyright (c) 2015 The Rust Project Developers
  - Copyright © 1991-2023 Unicode, Inc.
- Source: <https://github.com/unicode-rs/unicode-normalization>

### zmij 1.0.21

- License: MIT
- Its license files name no copyright holder. Its Cargo.toml lists the authors: David Tolnay <dtolnay@gmail.com>.
- Source: <https://github.com/dtolnay/zmij>

## Crates that run only while libjupynvim is built

These are procedural macros and what they use. The compiler runs them to
generate code; none of their own code is part of the library. They are listed
because `cargo tree` names them.

### phf_generator 0.11.3

- License: MIT
- Copyright (c) 2014-2022 Steven Fackler, Yuki Okushi
- Source: <https://github.com/rust-phf/rust-phf>

### phf_macros 0.11.3

- License: MIT
- Copyright (c) 2014-2022 Steven Fackler, Yuki Okushi
- Source: <https://github.com/rust-phf/rust-phf>

### proc-macro2 1.0.106

- License: MIT OR Apache-2.0
- Its license files name no copyright holder. Its Cargo.toml lists the authors: David Tolnay <dtolnay@gmail.com>, Alex Crichton <alex@alexcrichton.com>.
- Source: <https://github.com/dtolnay/proc-macro2>

### quote 1.0.45

- License: MIT OR Apache-2.0
- Its license files name no copyright holder. Its Cargo.toml lists the authors: David Tolnay <dtolnay@gmail.com>.
- Source: <https://github.com/dtolnay/quote>

### rand 0.8.6

- License: MIT OR Apache-2.0
- Copyright lines:
  - Copyright 2018 Developers of the Rand project
  - Copyright (c) 2014 The Rust Project Developers
- Its COPYRIGHT file: copyrights in the Rand project are retained by their contributors.
- Source: <https://github.com/rust-random/rand>

### rand_core 0.6.4

- License: MIT OR Apache-2.0
- Copyright lines:
  - Copyright 2018 Developers of the Rand project
  - Copyright (c) 2014 The Rust Project Developers
- Its COPYRIGHT file: copyrights in the Rand project are retained by their contributors.
- Source: <https://github.com/rust-random/rand>

### serde_derive 1.0.228

- License: MIT OR Apache-2.0
- Its license files name no copyright holder. Its Cargo.toml lists the authors: Erick Tryzelaar <erick.tryzelaar@gmail.com>, David Tolnay <dtolnay@gmail.com>.
- Source: <https://github.com/serde-rs/serde>

### syn 2.0.117

- License: MIT OR Apache-2.0
- Its license files name no copyright holder. Its Cargo.toml lists the authors: David Tolnay <dtolnay@gmail.com>.
- Source: <https://github.com/dtolnay/syn>

### thiserror-impl 1.0.69

- License: MIT OR Apache-2.0
- Its license files name no copyright holder. Its Cargo.toml lists the authors: David Tolnay <dtolnay@gmail.com>.
- Source: <https://github.com/dtolnay/thiserror>

### unicode-ident 1.0.24

- License: (MIT OR Apache-2.0) AND Unicode-3.0
- Copyright © 1991-2023 Unicode, Inc.
- Source: <https://github.com/dtolnay/unicode-ident>

## KaTeX fonts

`core/native/fonts/katex/` holds the 20 `KaTeX_*.ttf` fonts of the KaTeX project
(<https://github.com/KaTeX/KaTeX>), as RaTeX's `ratex-katex-fonts` 0.1.15 crate
ships them, byte for byte. 19 of them are embedded in `libjupynvim`, unmodified,
to draw display math; `KaTeX_Caligraphic-Bold.ttf` is kept with the set but not
embedded. They are licensed under the SIL Open Font License, Version 1.1 (its
text is below and in `core/native/fonts/katex/OFL.txt`).

The license description in the name table of every one of the fonts reads:

```text
Copyright (c) 2009-2010, Design Science, Inc. (<www.mathjax.org>)
Copyright (c) 2014-2018 Khan Academy (<www.khanacademy.org>),
with Reserved Font Name KaTeX_<family>.

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license available with a FAQ at:
http://scripts.sil.org/OFL
```

where `<family>` is the font's own family: AMS, Caligraphic, Fraktur, Main, Math,
SansSerif, Script, Size1, Size2, Size3, Size4 or Typewriter.

`core/native/fonts/katex/FONT_NOTICE.txt`, which comes with them:

```text
KaTeX font files (KaTeX_*.ttf)
================================

These TrueType fonts are taken from the KaTeX project:
  https://github.com/KaTeX/KaTeX

They are licensed under the SIL Open Font License, Version 1.1. The full
license text is in OFL.txt in this directory.

KaTeX's own MIT license applies to its software, not to the font binaries;
font licensing follows OFL as described in KaTeX's documentation and
upstream repository.
```

## License texts

### MIT

The copyright lines that go with this text are in each crate's entry above.
bytemuck's copy writes the second paragraph as "The above copyright notice and
this permission notice (including the next paragraph) shall be included in all
copies or substantial portions of the Software."

```text
Permission is hereby granted, free of charge, to any
person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the
Software without restriction, including without
limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software
is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice
shall be included in all copies or substantial portions
of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

### Apache-2.0

```text
                              Apache License
                        Version 2.0, January 2004
                     http://www.apache.org/licenses/

TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

1. Definitions.

   "License" shall mean the terms and conditions for use, reproduction,
   and distribution as defined by Sections 1 through 9 of this document.

   "Licensor" shall mean the copyright owner or entity authorized by
   the copyright owner that is granting the License.

   "Legal Entity" shall mean the union of the acting entity and all
   other entities that control, are controlled by, or are under common
   control with that entity. For the purposes of this definition,
   "control" means (i) the power, direct or indirect, to cause the
   direction or management of such entity, whether by contract or
   otherwise, or (ii) ownership of fifty percent (50%) or more of the
   outstanding shares, or (iii) beneficial ownership of such entity.

   "You" (or "Your") shall mean an individual or Legal Entity
   exercising permissions granted by this License.

   "Source" form shall mean the preferred form for making modifications,
   including but not limited to software source code, documentation
   source, and configuration files.

   "Object" form shall mean any form resulting from mechanical
   transformation or translation of a Source form, including but
   not limited to compiled object code, generated documentation,
   and conversions to other media types.

   "Work" shall mean the work of authorship, whether in Source or
   Object form, made available under the License, as indicated by a
   copyright notice that is included in or attached to the work
   (an example is provided in the Appendix below).

   "Derivative Works" shall mean any work, whether in Source or Object
   form, that is based on (or derived from) the Work and for which the
   editorial revisions, annotations, elaborations, or other modifications
   represent, as a whole, an original work of authorship. For the purposes
   of this License, Derivative Works shall not include works that remain
   separable from, or merely link (or bind by name) to the interfaces of,
   the Work and Derivative Works thereof.

   "Contribution" shall mean any work of authorship, including
   the original version of the Work and any modifications or additions
   to that Work or Derivative Works thereof, that is intentionally
   submitted to Licensor for inclusion in the Work by the copyright owner
   or by an individual or Legal Entity authorized to submit on behalf of
   the copyright owner. For the purposes of this definition, "submitted"
   means any form of electronic, verbal, or written communication sent
   to the Licensor or its representatives, including but not limited to
   communication on electronic mailing lists, source code control systems,
   and issue tracking systems that are managed by, or on behalf of, the
   Licensor for the purpose of discussing and improving the Work, but
   excluding communication that is conspicuously marked or otherwise
   designated in writing by the copyright owner as "Not a Contribution."

   "Contributor" shall mean Licensor and any individual or Legal Entity
   on behalf of whom a Contribution has been received by Licensor and
   subsequently incorporated within the Work.

2. Grant of Copyright License. Subject to the terms and conditions of
   this License, each Contributor hereby grants to You a perpetual,
   worldwide, non-exclusive, no-charge, royalty-free, irrevocable
   copyright license to reproduce, prepare Derivative Works of,
   publicly display, publicly perform, sublicense, and distribute the
   Work and such Derivative Works in Source or Object form.

3. Grant of Patent License. Subject to the terms and conditions of
   this License, each Contributor hereby grants to You a perpetual,
   worldwide, non-exclusive, no-charge, royalty-free, irrevocable
   (except as stated in this section) patent license to make, have made,
   use, offer to sell, sell, import, and otherwise transfer the Work,
   where such license applies only to those patent claims licensable
   by such Contributor that are necessarily infringed by their
   Contribution(s) alone or by combination of their Contribution(s)
   with the Work to which such Contribution(s) was submitted. If You
   institute patent litigation against any entity (including a
   cross-claim or counterclaim in a lawsuit) alleging that the Work
   or a Contribution incorporated within the Work constitutes direct
   or contributory patent infringement, then any patent licenses
   granted to You under this License for that Work shall terminate
   as of the date such litigation is filed.

4. Redistribution. You may reproduce and distribute copies of the
   Work or Derivative Works thereof in any medium, with or without
   modifications, and in Source or Object form, provided that You
   meet the following conditions:

   (a) You must give any other recipients of the Work or
       Derivative Works a copy of this License; and

   (b) You must cause any modified files to carry prominent notices
       stating that You changed the files; and

   (c) You must retain, in the Source form of any Derivative Works
       that You distribute, all copyright, patent, trademark, and
       attribution notices from the Source form of the Work,
       excluding those notices that do not pertain to any part of
       the Derivative Works; and

   (d) If the Work includes a "NOTICE" text file as part of its
       distribution, then any Derivative Works that You distribute must
       include a readable copy of the attribution notices contained
       within such NOTICE file, excluding those notices that do not
       pertain to any part of the Derivative Works, in at least one
       of the following places: within a NOTICE text file distributed
       as part of the Derivative Works; within the Source form or
       documentation, if provided along with the Derivative Works; or,
       within a display generated by the Derivative Works, if and
       wherever such third-party notices normally appear. The contents
       of the NOTICE file are for informational purposes only and
       do not modify the License. You may add Your own attribution
       notices within Derivative Works that You distribute, alongside
       or as an addendum to the NOTICE text from the Work, provided
       that such additional attribution notices cannot be construed
       as modifying the License.

   You may add Your own copyright statement to Your modifications and
   may provide additional or different license terms and conditions
   for use, reproduction, or distribution of Your modifications, or
   for any such Derivative Works as a whole, provided Your use,
   reproduction, and distribution of the Work otherwise complies with
   the conditions stated in this License.

5. Submission of Contributions. Unless You explicitly state otherwise,
   any Contribution intentionally submitted for inclusion in the Work
   by You to the Licensor shall be under the terms and conditions of
   this License, without any additional terms or conditions.
   Notwithstanding the above, nothing herein shall supersede or modify
   the terms of any separate license agreement you may have executed
   with Licensor regarding such Contributions.

6. Trademarks. This License does not grant permission to use the trade
   names, trademarks, service marks, or product names of the Licensor,
   except as required for reasonable and customary use in describing the
   origin of the Work and reproducing the content of the NOTICE file.

7. Disclaimer of Warranty. Unless required by applicable law or
   agreed to in writing, Licensor provides the Work (and each
   Contributor provides its Contributions) on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
   implied, including, without limitation, any warranties or conditions
   of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
   PARTICULAR PURPOSE. You are solely responsible for determining the
   appropriateness of using or redistributing the Work and assume any
   risks associated with Your exercise of permissions under this License.

8. Limitation of Liability. In no event and under no legal theory,
   whether in tort (including negligence), contract, or otherwise,
   unless required by applicable law (such as deliberate and grossly
   negligent acts) or agreed to in writing, shall any Contributor be
   liable to You for damages, including any direct, indirect, special,
   incidental, or consequential damages of any character arising as a
   result of this License or out of the use or inability to use the
   Work (including but not limited to damages for loss of goodwill,
   work stoppage, computer failure or malfunction, or any and all
   other commercial damages or losses), even if such Contributor
   has been advised of the possibility of such damages.

9. Accepting Warranty or Additional Liability. While redistributing
   the Work or Derivative Works thereof, You may choose to offer,
   and charge a fee for, acceptance of support, warranty, indemnity,
   or other liability obligations and/or rights consistent with this
   License. However, in accepting such obligations, You may act only
   on Your own behalf and on Your sole responsibility, not on behalf
   of any other Contributor, and only if You agree to indemnify,
   defend, and hold each Contributor harmless for any liability
   incurred by, or claims asserted against, such Contributor by reason
   of your accepting any such warranty or additional liability.

END OF TERMS AND CONDITIONS

APPENDIX: How to apply the Apache License to your work.

   To apply the Apache License to your work, attach the following
   boilerplate notice, with the fields enclosed by brackets "[]"
   replaced with your own identifying information. (Don't include
   the brackets!)  The text should be enclosed in the appropriate
   comment syntax for the file format. We also recommend that a
   file or class name and description of purpose be included on the
   same "printed page" as the copyright notice for easier
   identification within third-party archives.

Copyright [yyyy] [name of copyright owner]

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

	http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

### BSD-2-Clause

As arrayref's `LICENSE` has it:

```text
Copyright (c) 2015 David Roundy <roundyd@physics.oregonstate.edu>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the
   distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### BSD-3-Clause

As the `LICENSE` of tiny-skia and tiny-skia-path has it:

```text
Copyright (c) 2011 Google Inc. All rights reserved.
Copyright (c) 2020 Yevhenii Reizner All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of the copyright holder nor the names of its
    contributors may be used to endorse or promote products derived
    from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### Zlib

The copyright lines that go with this text are in each crate's entry above.

```text
This software is provided 'as-is', without any express or implied warranty. In no event will the authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the original software. If you use this software in a product, an acknowledgment in the product documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as being the original software.

3. This notice may not be removed or altered from any source distribution.
```

### 0BSD

As adler2's `LICENSE-0BSD` has it:

```text
Copyright (C) Jonas Schievink <jonasschievink@gmail.com>

Permission to use, copy, modify, and/or distribute this software for
any purpose with or without fee is hereby granted.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT
OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

### Unlicense

```text
This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or
distribute this software, either in source code form or as a compiled
binary, for any purpose, commercial or non-commercial, and by any
means.

In jurisdictions that recognize copyright laws, the author or authors
of this software dedicate any and all copyright interest in the
software to the public domain. We make this dedication for the benefit
of the public at large and to the detriment of our heirs and
successors. We intend this dedication to be an overt act of
relinquishment in perpetuity of all present and future rights to this
software under copyright law.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

For more information, please refer to <http://unlicense.org/>
```

### Unicode-3.0

```text
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2023 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.
```

### SIL Open Font License 1.1

```text
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded,
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```
