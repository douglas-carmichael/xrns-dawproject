import ConverterKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif canImport(ucrt)
import ucrt
#endif

// The real work lives in ConverterKit.runCLI so it can be unit tested; this
// executable just forwards the command-line arguments and maps the result to a
// process exit code.
exit(runCLI(Array(CommandLine.arguments.dropFirst())))
