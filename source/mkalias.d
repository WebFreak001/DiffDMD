module mkalias;

import core.atomic;
import std.conv;
import std.exception;
import std.file;
import std.format;
import std.path;
import std.process;

shared int aliasCounter = 0;

string makeAlias(string program, string[] args)
{
	if (args.length == 0)
		return program;

	int count = aliasCounter.atomicOp!"+="(1);
	auto ret = buildPath(tempDir, text(
		program.baseName.stripExtension,
		"-wrap-", thisProcessID, "-", count,
		program.extension
	));

	buildAlias(ret, program, args);

	return ret;
}

version (Windows)
void buildAlias(string output, string program, string[] args)
{
	string source = format!q{
		import core.sys.windows.windows;

		static immutable wstring program = %s;
		static immutable wstring cmdLine = %s;

		__gshared wchar[32_767] cmdLineConcat = void;

		extern (Windows)
		uint wmainCRTStartup()
		{
			auto inCmdLine = GetCommandLineW();
			size_t progEnd, length;
			bool inString = false;
			while (inCmdLine[length])
			{
				if (inCmdLine[length] == '"')
					inString = !inString;
				else if (!inString && inCmdLine[length] == ' ' && !progEnd)
					progEnd = length + 1;
				length++;
			}

			if (progEnd)
				length -= progEnd;
			else
				length = 0;

			if (length + 1 > cmdLineConcat.length - cmdLine.length)
				length = cmdLineConcat.length - cmdLine.length - 1; // cut off arguments

			cmdLineConcat.ptr[0 .. cmdLine.length] = cmdLine;
			cmdLineConcat.ptr[cmdLine.length .. cmdLine.length + length] =
				inCmdLine[progEnd .. progEnd + length];
			cmdLineConcat.ptr[cmdLine.length + length] = '\0';

			STARTUPINFOW info = void;
			info.cb = info.sizeof;
			info.dwFlags = STARTF_USESTDHANDLES;
			info.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
			info.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
			info.hStdError = GetStdHandle(STD_ERROR_HANDLE);
			PROCESS_INFORMATION proc;

			enum INHERIT_PARENT_AFFINITY = 0x00010000;

			if (!CreateProcessW(
					program.ptr,
					cmdLineConcat.ptr,
					null,
					null,
					true,
					INHERIT_PARENT_AFFINITY,
					null,
					null,
					&info,
					&proc))
				return -1;

			WaitForSingleObject(proc.hProcess, INFINITE);

			uint exitCode;
			if (!GetExitCodeProcess(proc.hProcess, &exitCode))
				return -1;

			return exitCode;
		}

		version(LDC)
		{
			extern (C) void _d_array_slice_copy(void* dst, size_t dstlen, void* src, size_t srclen, size_t elemsz)
			{
				for (size_t i = 0; i < srclen * elemsz; i++)
					(cast(ubyte*)dst)[i] = (cast(ubyte*)src)[i];
			}
		}

		extern(C) void _assert (
			const(void)* exp,
			const(void)* file,
			uint line
		)
		{
			ExitProcess(-1);
		}
	}(program.escapeDString, ((program ~ args).escapeShellCommand ~ ' ').escapeDString);

	auto p = pipeProcess(
		[`ldc2.exe`,
			`-O3`,
			`--betterC`,
			`--checkaction=halt`,
			`-L=/NODEFAULTLIB`,
			`-L=/ENTRY:wmainCRTStartup`,
			`-L=/SUBSYSTEM:CONSOLE`,
			`-of=` ~ output,
			`-`],
		Redirect.stdin);
	p.stdin.writeln(source);
	p.stdin.close();

	enforce(p.pid.wait == 0);
}

string escapeDString(string s)
{
	return [s].to!string[1 .. $ - 1];
}
