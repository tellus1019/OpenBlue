import AudioClients
import XCTest

final class InputClientsTests: XCTestCase {
  func testOtherReaderSurvivesEitherStopOrder() {
    let app = InputProcess(id: 1, pid: 10, running: true, devices: [124, 172])
    let quickTime = InputProcess(id: 2, pid: 20, running: true, devices: [172])
    let browser = InputProcess(id: 3, pid: 30, running: true, devices: [172])
    let unrelated = InputProcess(id: 4, pid: 40, running: true, devices: [124])
    for readers in [[quickTime, browser], [browser, quickTime]] {
      let count: ([InputProcess]) -> Int = {
        InputProcess.consumers(in: [app, unrelated] + $0, device: 172, excluding: 10).count
      }
      XCTAssertEqual(count([]), 0)
      XCTAssertEqual(count([readers[0]]), 1)
      XCTAssertEqual(count(readers), 2)
      let stopped = InputProcess(id: readers[0].id, pid: readers[0].pid,
                                 running: false, devices: [172])
      XCTAssertEqual(count([stopped, readers[1]]), 1)
      XCTAssertEqual(count([stopped]), 0)
    }
  }
}
