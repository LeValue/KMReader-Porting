#include "background_downloads.h"
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <sddl.h>
#include <taskschd.h>
#include <winrt/base.h>
#include <winrt/Windows.Networking.Connectivity.h>
#include <algorithm>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
struct Bstr {
  BSTR value;
  explicit Bstr(const std::wstring& text) : value(SysAllocString(text.c_str())) {}
  ~Bstr() { SysFreeString(value); }
  operator BSTR() const { return value; }
  Bstr(const Bstr&) = delete;
  Bstr& operator=(const Bstr&) = delete;
};
std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  const int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text.data(),static_cast<int>(text.size()),nullptr,0);
  if(!count) throw std::invalid_argument("Invalid UTF-8 argument");
  std::wstring result(count,L'\0');
  MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,text.data(),static_cast<int>(text.size()),result.data(),count);
  return result;
}
std::wstring Xml(const std::wstring& input) {
  std::wstring result;
  for(const auto c:input) {
    switch(c) {
      case L'&': result+=L"&amp;";break;
      case L'<': result+=L"&lt;";break;
      case L'>': result+=L"&gt;";break;
      case L'\"': result+=L"&quot;";break;
      case L'\'': result+=L"&apos;";break;
      default: if(c<32) throw std::invalid_argument("Invalid task argument");result+=c;
    }
  }
  return result;
}
// CommandLineToArgvW quoting, including trailing backslashes before a quote.
std::wstring Quote(const std::wstring& argument) {
  std::wstring output=L"\"";size_t slashes=0;
  for(const auto c:argument) {
    if(c==L'\\') {++slashes;continue;}
    output.append(c==L'\"'?slashes*2+1:slashes,L'\\');slashes=0;output+=c;
  }
  output.append(slashes*2,L'\\');output+=L'\"';return output;
}
std::wstring String(const Map& map,const char* key) {
  const auto it=map.find(Value(key));
  if(it==map.end() || !std::holds_alternative<std::string>(it->second)) throw std::invalid_argument("Missing task argument");
  return Wide(std::get<std::string>(it->second));
}
bool Boolean(const Map& map,const char* key) {
  const auto it=map.find(Value(key));
  return it!=map.end() && std::holds_alternative<bool>(it->second) && std::get<bool>(it->second);
}
void ValidateId(const std::wstring& id) {
  if(id.size()!=73 || id.substr(0,9)!=L"kmreader-" || !std::all_of(id.begin()+9,id.end(),[](wchar_t c) {
    return (c>=L'0'&&c<=L'9')||(c>=L'a'&&c<=L'f');
  })) throw std::invalid_argument("Invalid KMReader task identifier");
}
winrt::com_ptr<ITaskFolder> Folder(bool create) {
  winrt::com_ptr<ITaskService> service;
  winrt::check_hresult(CoCreateInstance(CLSID_TaskScheduler,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(service.put())));
  const VARIANT empty{};
  winrt::check_hresult(service->Connect(empty,empty,empty,empty));
  winrt::com_ptr<ITaskFolder> folder;
  const auto result=service->GetFolder(Bstr(L"\\KMReader"),folder.put());
  if(FAILED(result) && create) {
    winrt::com_ptr<ITaskFolder> root;
    winrt::check_hresult(service->GetFolder(Bstr(L"\\"),root.put()));
    const auto created=root->CreateFolder(Bstr(L"KMReader"),empty,folder.put());
    if(FAILED(created)) winrt::check_hresult(service->GetFolder(Bstr(L"\\KMReader"),folder.put()));
  } else if(FAILED(result) && result!=HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) && result!=HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND)) {
    winrt::check_hresult(result);
  }
  return folder;
}
std::wstring UserSid() {
  HANDLE raw=nullptr;
  if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&raw)) winrt::throw_last_error();
  DWORD size=0;GetTokenInformation(raw,TokenUser,nullptr,0,&size);
  std::vector<BYTE> data(size);
  if(!GetTokenInformation(raw,TokenUser,data.data(),size,&size)) {CloseHandle(raw);winrt::throw_last_error();}
  CloseHandle(raw);
  LPWSTR sid=nullptr;
  if(!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid,&sid)) winrt::throw_last_error();
  std::wstring result(sid);LocalFree(sid);return result;
}
void Schedule(const Map& args) {
  const auto id=String(args,"id");ValidateId(id);
  const auto directory=String(args,"directory"),server=String(args,"server");
  std::wstring executable(32768,L'\0');
  const DWORD length=GetModuleFileNameW(nullptr,executable.data(),static_cast<DWORD>(executable.size()));
  if(length==0 || length>=executable.size()) winrt::throw_last_error();
  executable.resize(length);
  const auto working=executable.substr(0,executable.find_last_of(L"\\/"));
  const auto arguments=L"--background-downloads "+Quote(directory)+L" "+Quote(server);
  const auto battery=Boolean(args,"charging")?L"true":L"false";
  const auto sid=UserSid();
  const std::wstring xml=L"<?xml version=\"1.0\" encoding=\"UTF-16\"?>"
    L"<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">"
    L"<RegistrationInfo><Description>KMReader offline downloads for the current Windows user</Description></RegistrationInfo>"
    L"<Triggers><RegistrationTrigger><Enabled>true</Enabled></RegistrationTrigger>"
    L"<TimeTrigger><Repetition><Interval>PT15M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>"
    L"<StartBoundary>2020-01-01T00:00:00</StartBoundary><Enabled>true</Enabled></TimeTrigger></Triggers>"
    L"<Principals><Principal id=\"User\"><UserId>"+Xml(sid)+L"</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>"
    L"<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>"+battery+
    L"</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>"+battery+
    L"</StopIfGoingOnBatteries><AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable>"
    L"<RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable><IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>"
    L"<AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled><Hidden>true</Hidden><ExecutionTimeLimit>PT0S</ExecutionTimeLimit>"
    L"<RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure></Settings>"
    L"<Actions Context=\"User\"><Exec><Command>"+Xml(executable)+L"</Command><Arguments>"+Xml(arguments)+L"</Arguments><WorkingDirectory>"+Xml(working)+L"</WorkingDirectory></Exec></Actions></Task>";
  auto folder=Folder(true);
  VARIANT user{};user.vt=VT_BSTR;const Bstr userText(sid);user.bstrVal=userText.value;
  const VARIANT empty{};winrt::com_ptr<IRegisteredTask> task;
  winrt::check_hresult(folder->RegisterTask(Bstr(id),Bstr(xml),TASK_CREATE_OR_UPDATE,user,empty,TASK_LOGON_INTERACTIVE_TOKEN,empty,task.put()));
}
void Cancel(const std::wstring& id) {
  ValidateId(id);auto folder=Folder(false);if(!folder) return;
  winrt::com_ptr<IRegisteredTask> task;
  if(SUCCEEDED(folder->GetTask(Bstr(id),task.put()))) task->Stop(0);
  const auto result=folder->DeleteTask(Bstr(id),0);
  if(result!=HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND)) winrt::check_hresult(result);
}
Value Conditions() {
  using namespace winrt::Windows::Networking::Connectivity;
  bool connected=false,metered=true;
  const auto profile=NetworkInformation::GetInternetConnectionProfile();
  if(profile) {
    connected=profile.GetNetworkConnectivityLevel()!=NetworkConnectivityLevel::None;
    const auto cost=profile.GetConnectionCost();
    metered=cost.NetworkCostType()!=NetworkCostType::Unrestricted || cost.Roaming() || cost.OverDataLimit();
  }
  SYSTEM_POWER_STATUS power{};const bool available=GetSystemPowerStatus(&power)!=0;
  return Value(Map{{Value("connected"),Value(connected)}, {Value("metered"),Value(metered)}, {Value("charging"),Value(available && power.ACLineStatus==1)}});
}
} // namespace

BackgroundDownloads::BackgroundDownloads(flutter::BinaryMessenger* messenger) {
  channel_=std::make_unique<flutter::MethodChannel<Value>>(messenger,"dev.levalue.kmreader/background",&flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([](const auto& call,auto result) {
    try {
      if(call.method_name()=="conditions") {result->Success(Conditions());return;}
      if(call.method_name()=="schedule") {
        const auto* args=call.arguments()?std::get_if<Map>(call.arguments()):nullptr;
        if(!args) throw std::invalid_argument("Missing task arguments");
        Schedule(*args);result->Success();return;
      }
      if(call.method_name()=="cancel") {
        const auto* id=call.arguments()?std::get_if<std::string>(call.arguments()):nullptr;
        if(!id) throw std::invalid_argument("Missing task identifier");
        Cancel(Wide(*id));result->Success();return;
      }
      result->NotImplemented();
    } catch(const winrt::hresult_error&) {
      result->Error("background_unavailable","Windows could not update background downloads. Check Task Scheduler permissions.");
    } catch(const std::exception& error) {
      result->Error("background_arguments",error.what());
    }
  });
}
BackgroundDownloads::~BackgroundDownloads() {channel_->SetMethodCallHandler(nullptr);}
