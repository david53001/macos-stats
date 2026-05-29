import Testing
@testable import MacStatsCore

@Suite struct RingBufferTests {
    @Test func keepsOnlyLastCapacityValuesInOrder() {
        var buf = RingBuffer<Int>(capacity: 3)
        buf.append(1); buf.append(2); buf.append(3); buf.append(4)
        #expect(buf.values == [2, 3, 4])
        #expect(buf.count == 3)
    }

    @Test func underCapacityKeepsAll() {
        var buf = RingBuffer<Int>(capacity: 5)
        buf.append(7); buf.append(8)
        #expect(buf.values == [7, 8])
    }
}
