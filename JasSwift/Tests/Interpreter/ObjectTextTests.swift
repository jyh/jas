import Foundation
import Testing
@testable import JasLib

// Census row #50: an object's text is compact JSON with sorted keys and an
// unescaped `/`, in all three runners (the reference's
// `test_an_object_in_a_list_is_its_sorted_compact_json`, Rust
// `an_object_is_its_sorted_compact_json`). Unsorted, the order changed from
// run to run of one binary.
@Test func anObjectIsItsSortedCompactJson() {
    let v = Value.fromJson(["b": 1, "a": "x/y", "c": [true, NSNull()]] as [String: Any])
    #expect(v.toStringCoerce() == #"{"a":"x/y","b":1,"c":[true,null]}"#)
}
