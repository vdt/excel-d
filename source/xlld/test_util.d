module xlld.test_util;

version(unittest):

import unit_threaded;

import xlld.xlcall: LPXLOPER12, XLOPER12, XlType;

TestAllocator gTestAllocator;
/// emulates SRef types by storing what the referenced type actually is
XlType gReferencedType;

// tracks calls to `coerce` and `free` to make sure memory allocations/deallocations match
int gNumXlCoerce;
int gNumXlFree;
enum maxCoerce = 1000;
void*[maxCoerce] gCoerced;
void*[maxCoerce] gFreed;
double[] gDates;
double[] gTimes;


extern(Windows) int excel12UnitTest(int xlfn, int numOpers, LPXLOPER12 *opers, LPXLOPER12 result) nothrow @nogc {

    import xlld.xlcall;
    import xlld.wrap: toXlOper;
    import std.experimental.allocator.mallocator: Mallocator;
    import std.array: front, popFront, empty;

    switch(xlfn) {

    default:
        return xlretFailed;

    case xlFree:
        assert(numOpers == 1);
        auto oper = opers[0];

        gFreed[gNumXlFree++] = oper.val.str;

        if(oper.xltype == XlType.xltypeStr)
            *oper = "".toXlOper(Mallocator.instance);

        return xlretSuccess;

    case xlCoerce:
        assert(numOpers == 1);

        auto oper = opers[0];
        gCoerced[gNumXlCoerce++] = oper.val.str;
        *result = *oper;

        switch(oper.xltype) with(XlType) {

            case xltypeSRef:
                result.xltype = gReferencedType;
                break;

            case xltypeNum:
            case xltypeStr:
                result.xltype = oper.xltype;
                break;

            case xltypeMissing:
                result.xltype = xltypeNil;
                break;

            default:
        }

        return xlretSuccess;

    case xlfDate:

        const ret = gDates.empty ? 0.0 : gDates.front;
        if(!gDates.empty) gDates.popFront;
        *result = ret.toXlOper(Mallocator.instance);
        return xlretSuccess;

    case xlfTime:
        const ret = gTimes.empty ? 0.0 : gTimes.front;
        if(!gTimes.empty) gTimes.popFront;

        *result = ret.toXlOper(Mallocator.instance);
        return xlretSuccess;
    }
}

// automatically converts from oper to compare with a D type
void shouldEqualDlang(U)(LPXLOPER12 actual, U expected, string file = __FILE__, size_t line = __LINE__) @trusted {
    import xlld.memorymanager: allocator;
    import xlld.wrap: fromXlOper;
    import xlld.xlcall: XlType;

    actual.shouldNotBeNull;
    if(actual.xltype == XlType.xltypeErr)
        fail("XLOPER is of error type", file, line);
    actual.fromXlOper!U(allocator).shouldEqual(expected, file, line);
}

// automatically converts from oper to compare with a D type
void shouldEqualDlang(U)(ref XLOPER12 actual, U expected, string file = __FILE__, size_t line = __LINE__) @trusted {
    shouldEqualDlang(&actual, expected, file, line);
}

// automatically converts from oper to compare with a D type
void shouldEqualDlang(U)(XLOPER12 actual, U expected, string file = __FILE__, size_t line = __LINE__) @trusted {
    shouldEqualDlang(actual, expected, file, line);
}


XLOPER12 toSRef(T, A)(T val, ref A allocator) @trusted {
    import xlld.wrap: toXlOper;

    auto ret = toXlOper(val, allocator);
    //hide real type somewhere to retrieve it
    gReferencedType = ret.xltype;
    ret.xltype = XlType.xltypeSRef;
    return ret;
}


// tracks allocations and throws in the destructor if there is a memory leak
// it also throws when there is an attempt to deallocate memory that wasn't
// allocated
struct TestAllocator {
    import std.experimental.allocator.common: platformAlignment;
    import std.experimental.allocator.mallocator: Mallocator;

    alias allocator = Mallocator.instance;

    private static struct ByteRange {
        void* ptr;
        size_t length;
        inout(void)[] opSlice() @trusted @nogc inout nothrow {
            return ptr[0 .. length];
        }
    }

    private ByteRange[] _allocations;
    private int _numAllocations;

    enum uint alignment = platformAlignment;

    void[] allocate(size_t numBytes) @safe @nogc {
        import std.experimental.allocator: makeArray, expandArray;

        static const exception = new Exception("Allocation failed");

        ++_numAllocations;

        auto ret = allocator.allocate(numBytes);
        if(numBytes > 0 && ret.length == 0)
            throw exception;

        auto newEntry = ByteRange(&ret[0], ret.length);

        if(_allocations is null)
            _allocations = allocator.makeArray(1, newEntry);
        else
            () @trusted { allocator.expandArray(_allocations, 1, newEntry); }();

        return ret;
    }

    bool deallocate(void[] bytes) @trusted @nogc nothrow {
        import std.algorithm: remove, canFind;
        import core.stdc.stdio: sprintf;

        bool pred(ByteRange other) { return other.ptr == bytes.ptr && other.length == bytes.length; }

        static char[1024] buffer;

        if(!_allocations.canFind!pred) {
            auto index = sprintf(&buffer[0],
                                 "Unknown deallocate byte range. Ptr: %p, length: %ld, allocations:\n",
                                 &bytes[0], bytes.length);
            index = printAllocations(buffer, index);
            assert(false, buffer[0 .. index]);
        }

        _allocations = _allocations.remove!pred;

        return () @trusted { return allocator.deallocate(bytes); }();
    }

    bool deallocateAll() @safe @nogc nothrow {
        foreach(ref allocation; _allocations) {
            deallocate(allocation[]);
        }
        return true;
    }

    auto numAllocations() @safe @nogc pure nothrow const {
        return _numAllocations;
    }

    ~this() @safe @nogc nothrow {
        verify;
    }

    void verify() @trusted @nogc nothrow {

        static char[1024] buffer;

        if(_allocations.length) {
            import core.stdc.stdio: sprintf;
            auto index = sprintf(&buffer[0], "Memory leak in TestAllocator. Allocations:\n");
            index = printAllocations(buffer, index);
            assert(false, buffer[0 .. index]);
        }
    }

    int printAllocations(int N)(ref char[N] buffer, int index = 0) @trusted @nogc const nothrow {
        import core.stdc.stdio: sprintf;
        index += sprintf(&buffer[index], "[");
        foreach(ref allocation; _allocations) {
            index += sprintf(&buffer[index], "ByteRange(%p, %ld), ",
                             allocation.ptr, allocation.length);
        }

        index += sprintf(&buffer[index], "]");
        return index;
    }
}
