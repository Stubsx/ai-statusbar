import Foundation
import SQLite3

enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    var string: String? {
        switch self {
        case .text(let value): return value
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        case .null: return nil
        }
    }

    var int: Int? {
        switch self {
        case .integer(let value): return Int(value)
        case .real(let value): return Int(value)
        case .text(let value): return Int(value)
        case .null: return nil
        }
    }

    var double: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .real(let value): return value
        case .text(let value): return Double(value)
        case .null: return nil
        }
    }
}

enum SQLiteBind {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null
}

enum SQLiteError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): return message
        }
    }
}

final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, readOnly: Bool = false) throws {
        let flags =
            readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let target = readOnly ? "file:\(path)?mode=ro" : path
        guard sqlite3_open_v2(target, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开 SQLite 数据库"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError.message(message)
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func execute(_ sql: String, binds: [SQLiteBind] = []) throws {
        let statement = try prepare(sql, binds: binds)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentError() }
    }

    func query(_ sql: String, binds: [SQLiteBind] = []) throws -> [[String: SQLiteValue]] {
        let statement = try prepare(sql, binds: binds)
        defer { sqlite3_finalize(statement) }
        var rows: [[String: SQLiteValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw currentError() }
            var row: [String: SQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    row[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    row[name] =
                        sqlite3_column_text(statement, index).map {
                            .text(String(cString: $0))
                        } ?? .null
                default:
                    row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    func columns(in table: String) throws -> Set<String> {
        Set(try query("PRAGMA table_info(\(table))").compactMap { $0["name"]?.string })
    }

    private func prepare(_ sql: String, binds: [SQLiteBind]) throws -> OpaquePointer {
        guard let handle else { throw SQLiteError.message("数据库已关闭") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw currentError() }
        do {
            for (offset, bind) in binds.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch bind {
                case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
                case .real(let value): result = sqlite3_bind_double(statement, index, value)
                case .text(let value):
                    result = sqlite3_bind_text(statement, index, value, -1, transient)
                case .null: result = sqlite3_bind_null(statement, index)
                }
                guard result == SQLITE_OK else { throw currentError() }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func currentError() -> SQLiteError {
        guard let handle else { return .message("数据库已关闭") }
        return .message(String(cString: sqlite3_errmsg(handle)))
    }
}
