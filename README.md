This is basically the [Process from the old Foundation](https://developer.apple.com/documentation/foundation/process) upgraded to `async/await`. It is very similar to Python [asyncio.subprocess](https://docs.python.org/3/library/asyncio-subprocess.html).

Linux.

macOS mostly works, but I did not test edge cases.

Do not use! This is a toy. But at least it does not deadlocks/hangs/crashes child/blocks cooperative threads/goes into an infinite loop etc.
