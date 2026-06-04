//
//  StreamingSessionDelegateRouter.swift
//  Loop
//
//  Routes URLSessionDataDelegate callbacks to the correct stream reader
//  for each in-flight streaming task. URLSession's delegate-based flow
//  requires a single delegate per session; this class multiplexes
//  between SSEStreamReader (OpenAI/Fireworks) and AnthropicStreamReader.
//

import Foundation

final class StreamingSessionDelegateRouter: NSObject, URLSessionDataDelegate {

    /// Any object conforming to URLSessionDataDelegate can be registered.
    private var readers: [Int: URLSessionDataDelegate] = [:]
    private let lock = NSLock()

    func register(task: URLSessionDataTask, reader: URLSessionDataDelegate) {
        lock.lock(); defer { lock.unlock() }
        readers[task.taskIdentifier] = reader
    }

    private func reader(for task: URLSessionTask) -> URLSessionDataDelegate? {
        lock.lock(); defer { lock.unlock() }
        return readers[task.taskIdentifier]
    }

    private func removeReader(for task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        readers.removeValue(forKey: task.taskIdentifier)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let r = reader(for: dataTask) {
            r.urlSession?(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        reader(for: dataTask)?.urlSession?(session, dataTask: dataTask, didReceive: data)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        reader(for: task)?.urlSession?(session, task: task, didCompleteWithError: error)
        removeReader(for: task)
    }
}
