When [last we talked about type erasure](http://robnapier.net/erasure), I described an easy way to build type erasures using closures. And I mentioned:

> (While this works exactly like AnySequence, this isn’t how AnySequence is implemented. In my next post I’ll discuss why and how to implement type erasers like stdlib does.)

At the time I thought I'd pretty well nailed it down, but every time I dug into it I found another little thing I'd missed, and it never seemed to end. And with stdlib open sourcing soon, you'll all just be able to read this yourselves, so why embarrass myself getting it all wrong? Over time I kind of hoped you all had forgotten that comment and planned to move on to other things. But then I was [busted by Michael Welch](https://twitter.com/My_kl/status/650796108789219328), and so I had to finish the spelunking and here you go.

So, here is my annotated implementation of `AnyGenerator` and `AnySequence` that I believe pretty closely matches Apple's implementation in stdlib (minus some low-level optimizations in `AnySequence` that I'll call out when we get there). I've named my versions of public symbols with a trailing underscore to differentiate from the Swift version. For private symbols (with leading underscore), I've used the same name Swift does.

All type information was determined using `:type lookup` in the Swift REPL. In a few places I checked the implementation with Hopper, but in most cases, once you have the types, the implementation is obvious. (There's a deep lesson in there if you pay attention.)
