#include <windows.h>
#include <stdio.h>
#include <wchar.h>

typedef struct Blob Blob;
typedef struct BlobVtbl {
	void *qi;
	void *addref;
	ULONG (__stdcall *Release)(Blob *);
	void *(__stdcall *GetBufferPointer)(Blob *);
	SIZE_T (__stdcall *GetBufferSize)(Blob *);
} BlobVtbl;
struct Blob { BlobVtbl *v; };

typedef HRESULT (__stdcall *CompileFromFile)(const wchar_t *, const void *, void *, const char *, const char *, UINT, UINT, Blob **, Blob **);

static void narrow(const wchar_t *in, char *out, int size)
{
	WideCharToMultiByte(CP_UTF8, 0, in, -1, out, size, NULL, NULL);
}

int wmain(int argc, wchar_t **argv)
{
	const wchar_t *input = NULL, *output = NULL;
	char profile[32] = "", entry[64] = "main";
	UINT flags = 0;

	for (int i = 1; i < argc; i++) {
		const wchar_t *a = argv[i];
		if (a[0] != L'/' && a[0] != L'-') { input = a; continue; }
		a++;
		if (!wcscmp(a, L"T") && i + 1 < argc) narrow(argv[++i], profile, sizeof(profile));
		else if (a[0] == L'T' && a[1]) narrow(a + 1, profile, sizeof(profile));
		else if (!wcscmp(a, L"E") && i + 1 < argc) narrow(argv[++i], entry, sizeof(entry));
		else if (a[0] == L'E' && a[1]) narrow(a + 1, entry, sizeof(entry));
		else if (!wcscmp(a, L"Fo") && i + 1 < argc) output = argv[++i];
		else if (!wcsncmp(a, L"Fo", 2) && a[2]) output = a + 2;
		else if (!wcscmp(a, L"Gec")) flags |= 1u << 12;
		else if (!wcscmp(a, L"O3")) flags |= 1u << 15;
		else if (!wcscmp(a, L"nologo")) {}
		else { fwprintf(stderr, L"unsupported switch /%ls\n", a); return 2; }
	}

	if (!input || !output || !profile[0]) {
		fwprintf(stderr, L"usage: d3dc [/Gec] [/O3] /T profile [/E entry] /Fo out in.hlsl\n");
		return 2;
	}

	HMODULE dll = LoadLibraryW(L"d3dcompiler_47.dll");
	if (!dll) { fwprintf(stderr, L"no d3dcompiler_47.dll\n"); return 2; }
	CompileFromFile compile = (CompileFromFile)GetProcAddress(dll, "D3DCompileFromFile");

	Blob *code = NULL, *errors = NULL;
	HRESULT hr = compile(input, NULL, (void *)(INT_PTR)1, entry, profile, flags, 0, &code, &errors);
	if (errors) {
		fwrite(errors->v->GetBufferPointer(errors), 1, errors->v->GetBufferSize(errors), stderr);
		errors->v->Release(errors);
	}
	if (FAILED(hr) || !code) { fwprintf(stderr, L"compile failed 0x%08lx\n", hr); return 1; }

	FILE *f = _wfopen(output, L"wb");
	if (!f) { fwprintf(stderr, L"cannot write %ls\n", output); return 1; }
	fwrite(code->v->GetBufferPointer(code), 1, code->v->GetBufferSize(code), f);
	fclose(f);
	code->v->Release(code);

	return 0;
}
