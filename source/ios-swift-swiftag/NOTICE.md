# NOTICE

This subfolder vendors a snapshot of SwiftAg, a Swift-native
multi-agent runtime. SwiftAg is conceptually descended from
[AG2 (formerly AutoGen)](https://github.com/ag2ai/ag2), licensed
under the Apache License, Version 2.0. AG2 in turn carries portions
of the original
[microsoft/autogen](https://github.com/microsoft/autogen) under the
MIT License (Copyright (c) Microsoft Corporation).

No source code from AG2 or microsoft/autogen has been copied or
translated into this snapshot. SwiftAg is an independent Swift
implementation that re-derives the public API surface (Agent,
ConversableAgent, GroupChat patterns, Tool, LLMConfig, …) from the
publicly documented behaviour of AG2.

Attribution is preserved here per Apache-2.0 section 4(c) and out
of respect for the upstream MIT contributions:

```
AG2 contains portions of code originally developed as part of the
Microsoft AutoGen project (https://github.com/microsoft/autogen),
which is licensed under the MIT License.

Copyright (c) Microsoft Corporation.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use, copy,
modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

This `source/ios-swift-swiftag/` subfolder, as committed in
`hggz/AdaptiveCards-Mobile` and `hggzm/Teams-AdaptiveCards-Mobile`,
inherits the repo-root MIT license. No nested `LICENSE` file is
included.
