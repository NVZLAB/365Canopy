using Microsoft.Win32;
using System.Windows;
using System.Windows.Media;

namespace Canopy.Desktop;
// Same resource and accessibility logic as Lantern, with Canopy's green accent.
public sealed class ThemeService : IDisposable
{
    string mode="System";
    public ThemeService()=>SystemEvents.UserPreferenceChanged+=OnChanged;
    public void Set(string value){mode=value;Apply();}
    void OnChanged(object sender,UserPreferenceChangedEventArgs e)=>Application.Current.Dispatcher.InvokeAsync(Apply);
    void Apply()
    {
        bool dark=mode=="Dark";
        if(mode=="System"){using var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");dark=key?.GetValue("AppsUseLightTheme") is int value&&value==0;}
        Application.Current.ThemeMode=mode switch{"Dark"=>ThemeMode.Dark,"Light"=>ThemeMode.Light,_=>ThemeMode.System};
        string[] colors=dark?new[]{"#111A16","#1B2821","#EDF3EF","#B1C4B8","#344B3E","#7DDB9E"}:new[]{"#F5F8F6","#FFFFFF","#182D21","#51685B","#DFE8E2","#176940"};
        string[] keys={"PageBrush","CardBrush","InkBrush","MutedBrush","LineBrush","AccentBrush"};
        for(int i=0;i<keys.Length;i++)Application.Current.Resources[keys[i]]=new SolidColorBrush((Color)ColorConverter.ConvertFromString(colors[i]));
        if(SystemParameters.HighContrast){Application.Current.Resources["PageBrush"]=SystemColors.WindowBrush;Application.Current.Resources["CardBrush"]=SystemColors.WindowBrush;Application.Current.Resources["InkBrush"]=SystemColors.WindowTextBrush;Application.Current.Resources["MutedBrush"]=SystemColors.WindowTextBrush;Application.Current.Resources["LineBrush"]=SystemColors.WindowTextBrush;Application.Current.Resources["AccentBrush"]=SystemColors.HighlightBrush;}
    }
    public void Dispose()=>SystemEvents.UserPreferenceChanged-=OnChanged;
}
