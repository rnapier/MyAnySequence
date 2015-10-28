/*:
When [last we talked about type erasure](http://robnapier.net/erasure), I described an easy way to build type erasures using closures. And I mentioned:

> (While this works exactly like AnySequence, this isn’t how AnySequence is implemented. In my next post I’ll discuss why and how to implement type erasers like stdlib does.)

At the time I thought I'd pretty well nailed it down, but every time I dug into it I found another little thing I'd missed, and it never seemed to end. And with stdlib open sourcing soon, you'll all just be able to read this yourselves, so why embarrass myself getting it all wrong? Over time I kind of hoped you all had forgotten that comment and planned to move on to other things. But then I was [busted by Michael Welch](https://twitter.com/My_kl/status/650796108789219328), and so I had to finish the spelunking and here you go.

So, here is my annotated implementation of `AnyGenerator` and `AnySequence` that I believe pretty closely matches Apple's implementation in stdlib (minus some low-level optimizations in `AnySequence` that I'll call out when we get there). I've named my versions of public symbols with a trailing underscore to differentiate from the Swift version. For private symbols (with leading underscore), I've used the same name Swift does.

All type information was determined using `:type lookup` in the Swift REPL. In a few places I checked the implementation with Hopper, but in most cases, once you have the types, the implementation is obvious. (There's a deep lesson in there if you pay attention.)
*/

/*:
# AnyGenerator

We'll start with `AnyGenerator`, which is one of the most un-Swift-like things I know in stdlib. It's abstract, and it tests its own type in `init()` to make sure you didn't call it directly. I reproduced `init` by decompiling it (though it may use `if` rather than `guard`).

The typical way to create an `AnyGenerator` is by calling the factory function `anyGenerator`, which is unlike any other type eraser in Swift.

See `MyAnyGenerator` at the end for a version that I think has a much more Swift-like API.
*/

@noreturn func _abstract(file: StaticString = __FILE__, line: UInt = __LINE__) {
    fatalError("Method must be overridden", file: file, line: line)
}

class AnyGenerator_<Element> : _AnyGeneratorBase, GeneratorType, SequenceType {
    override init() {
        guard self.dynamicType != AnyGenerator_.self else {
            fatalError("AnyGenerator<Element> instances can not be created; create a subclass instance instead")
        }
    }
    func next() -> Element? {
        _abstract()
    }
}

func anyGenerator_<G : GeneratorType>(base: G) -> AnyGenerator_<G.Element> {
    return _GeneratorBox(base)
}

func anyGenerator_<Element>(body: () -> Element?) -> AnyGenerator_<Element> {
    return _FunctionGenerator(body)
}

/*:
## _AnyGeneratorBase

`_AnyGeneratorBase` is the secret to type erasure in `AnyGenerator`. It's kind of `AnyAnyGenerator` in that you don't have to type-specialize it, which means you can put it places a generic couldn't go (as we'll see when we get to `AnySequence`). Like `AnyObject`, you can't use an `_AnyGeneratorBase` directly. You must `as‽` it to some subclass.
*/
class _AnyGeneratorBase {} // You were expecting something complicated?

/*:
## Concrete AnyGenerators

`_GeneratorBox` and `_FunctionGenerator` are the two private subclasses of `AnyGenerator`, one for wrapping another generator, and one for wrapping a `next()` function. They're pretty standard boxes except for their types. Notice how they use subclassing to transform specialization by the generator into specialization by the element.
*/
final class _GeneratorBox<Base : GeneratorType> : AnyGenerator_<Base.Element> {
    var base: Base
    init(_ base: Base) { self.base = base }
    override func next() -> Base.Element? {
        return base.next()
    }
}

class _FunctionGenerator<Element> : AnyGenerator_<Element> {
    final let body: () -> Element?
    init (_ body: () -> Element?) { self.body = body }
    override func next() -> Element? {
        return body()
    }
}

/*:
## Another way to have done AnyGenerator

`AnyGenerator` has a terrible API, IMO. It should be possible to use its constructors directly, and `AnyGenerator<Int>()` should give an empty generator, not one that crashes at runtime. 

Here's one possible approach. The cost is a little memory (for `box`) and a little more indirection in the dispatch.
*/

final class MyAnyGenerator<Element> : _AnyGeneratorBase, GeneratorType, SequenceType {
    private var box: AnyGenerator_<Element>? = nil
    override init() {}
    init<G : GeneratorType where G.Element == Element>(_ base: G) {
        box = _GeneratorBox(base)
    }
    init(_ body: () -> Element?) {
        box = _FunctionGenerator(body)
    }
    func next() -> Element? {
        return box?.next()
    }
}

/*:
## Test cases for AnyGenerator

Here are some examples you can use to explore how this version compares with the stdlib version.
*/

func show(x: Any) -> String {
    var out = ""
    dump(x, &out)
    return out
}

let a = [1,2,3]
func makeFunc() -> () -> Int? {
    var n = 0
    return {
        if n++ >= 3 {
            return nil
        }
        return n
    }
}

//: ### stdlib AnyGenerator<Int> using another generator
var xsg = anyGenerator(a.generate())
show(xsg)

//: ### Rewritten AnyGenerator<Int> using another generator
var xsg_ = anyGenerator_(a.generate())
show(xsg_)

//: ### stdlib AnyGenerator<Int> using a closure
var fg: AnyGenerator<Int> = anyGenerator(makeFunc())
show(fg)

//: ### Rewritten AnyGenerator<Int> using a closure
var fg_: AnyGenerator_<Int> = anyGenerator_(makeFunc())
show(fg_)

//: ----

/*:
# AnySequence

Once you understand AnyGenerator, AnySequence is pretty simple, at least in the simplified version I'm going to show here. The stdlib version includes a lot of internal optimization methods that aren't directly related to type-erasure, and I haven't tried to reproduce them:

    func _underestimateCount() -> Int
    func _initializeTo(ptr: UnsafeMutablePointer<Void>) -> UnsafeMutablePointer<Void>
    func _copyToNativeArrayBuffer() -> Swift._ContiguousArrayStorageBase

I'll include these as comments where they go.

The top-level `AnySequence` shouldn't be much of a surprise. Like `AnyGenerator`, there's a "generic-subclass of non-generic superclass" trick that let's us hold a type we can't specialize directly. The most noteworthy piece is the requirement to `as!` the result of `generate()` back to the type we know it has to be, but the language isn't powerful enough to express.
*/

struct AnySequence_<Element> : SequenceType {
    let _box: _AnySequenceBox

    init<S : SequenceType where S.Generator.Element == Element>(_ base: S) {
        _box = _SequenceBox(base)
    }

    init<G : GeneratorType where G.Element == Element>(_ makeUnderlyingGenerator: () -> G) {
        _box = _SequenceBox(_ClosureBasedSequence(makeUnderlyingGenerator))
    }

    func generate() -> AnyGenerator_<Element> {
        return _box.generate() as! AnyGenerator_<Element>
    }
}

/*:
## The box

And here is the "generic-subclass of a non-generic superclass" two-step. `_SequenceBox` boxes a `SequenceType`, just as the name says. Notice how it generates an abstract (not generic) `_AnyGeneratorBase`.
*/

class _AnySequenceBox {
    func generate() -> _AnyGeneratorBase {
        fatalError()
    }
    //  func _underestimateCount() -> Swift.Int
    //  func _initializeTo(ptr: Swift.UnsafeMutablePointer<Swift.Void>) -> Swift.UnsafeMutablePointer<Swift.Void>
    //  func _copyToNativeArrayBuffer() -> Swift._ContiguousArrayStorageBase
}

class _SequenceBox<Seq: SequenceType>: _AnySequenceBox {
    let _base: Seq
    init(_ base: Seq) { _base = base }
    override func generate() -> _AnyGeneratorBase {
        return anyGenerator_(_base.generate())
    }
    //  override func _underestimateCount() -> Swift.Int
    //  override func _initializeTo(ptr: Swift.UnsafeMutablePointer<Swift.Void>) -> Swift.UnsafeMutablePointer<Swift.Void>
    //  override func _copyToNativeArrayBuffer() -> Swift._ContiguousArrayStorageBase
}

/*:
## Closures

`_AnySequenceBox` handles sequences, but we also want to be able to handle a `generate()` closure. We can just wrap that into a `SequenceType`.
*/

struct _ClosureBasedSequence<G: GeneratorType>: SequenceType {
    let _makeUnderlyingGenerator: () -> G
    init(_ makeUnderlyingGenerator: () -> G) {
        _makeUnderlyingGenerator = makeUnderlyingGenerator
    }
    func generate() -> G {
        return _makeUnderlyingGenerator()
    }
}

//: ## Tests

//: ### stdlib AnySequence<Int> using another sequence
let xss = AnySequence(a)
show(xss)

//: ### Rewritten AnySequence<Int> using another sequence
let xss_ = AnySequence_(a)
show(xss_)

//: ### stdlib AnySequence<Int> using a generate() closure
let fss = AnySequence(a.generate)
show(fss)

//: ### Rewritten AnySequence<Int> using a generate() closure
let fss_ = AnySequence_(a.generate)
show(fss_)

//: ----

/*:
# ???

So why did Apple do it with all these boxes and wrappers and abstract tomfoolery rather than just closures? Why not implement `AnyGenerator` and `AnySequence` this way? (This is the whole implementation. No helpers needed.)
*/

public final class AnyGenerator__<Element> : GeneratorType, SequenceType {
    private let _next: () -> Element?
    public init<G : GeneratorType where G.Element == Element>(var _ base: G) {
        _next = { return base.next() }
    }
    public init(_ body: () -> Element?) {
        _next = body
    }
    public func next() -> Element? {
        return _next()
    }
}

public struct AnySequence__<Element> : SequenceType {
    private let _generate: () -> AnyGenerator__<Element>

    public init<S : SequenceType where S.Generator.Element == Element>(_ base: S) {
        _generate = { return AnyGenerator__(base.generate()) }
    }

    public init<G : GeneratorType where G.Element == Element>(_ makeUnderlyingGenerator: () -> G) {
        _generate = { AnyGenerator__(makeUnderlyingGenerator()) }
    }

    public func generate() -> AnyGenerator__<Element> {
        return _generate()
    }
}

/*:
I'm really not sure. My guess would be something related to performance or optimizations. There are a number of optimizations I didn't include, and maybe those are harder this way (though I'm not certain how that would be true). These may take a little more memory to hold the closure, but we'd be talking about a few bytes and there shouldn't be that many of these in the system. It's possible that going through the closure is slower than dynamic dispatch or interferes with optimizations (though dynamic dispatch also typically interferes with optimizations). But in the end, I don't know.

History suggests that when Apple's implementation is dramatically more complicated than mine, I missed a subtle but important issue (sometimes one that impacts foundational code much more than day-to-day stuff, sometimes a tricky fact about the current or recent compiler). I'd love to find out what it is. But for usual day-to-day type-erasure, I recomend closures. They're so much easier than this.

And of course the possibility remains that I got important parts of this wrong. We'll know when stdlib is open source.
*/

//: # Copyright and public domain notice
//: The text of the article, marked in /*: */ blocks, is Copyright 2015 by Rob Napier.
//:
//: Except where otherwise indicated, all source code in this article is public domain:
//:
//: This is free and unencumbered software released into the public domain.
//:
//: Anyone is free to copy, modify, publish, use, compile, sell, or distribute this software, either in source code form or as a compiled binary, for any purpose, commercial or non-commercial, and by any means.
//:
//: In jurisdictions that recognize copyright laws, the author or authors of this software dedicate any and all copyright interest in the software to the public domain. We make this dedication for the benefit of the public at large and to the detriment of our heirs and successors. We intend this dedication to be an overt act of relinquishment in perpetuity of all present and future rights to this software under copyright law.
//:
//: THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//:
//: For more information, please refer to <http://unlicense.org/>

