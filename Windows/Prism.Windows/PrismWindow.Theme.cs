using System.IO;
using System.Windows;
using System.Windows.Markup;
using System.Windows.Media;

namespace Prism.Windows;

public sealed partial class PrismWindow
{
    void InstallStyles()
    {
        var location = new Uri(Path.GetFullPath(AppContext.BaseDirectory) + Path.DirectorySeparatorChar);
        Resources["UiFont"] = new FontFamily(location, "./Fonts/#Sora");
        Resources["DisplayFont"] = new FontFamily(location, "./Fonts/#Space Grotesk");
        Resources["MonoFont"] = new FontFamily(location, "./Fonts/#JetBrains Mono");
        var dictionary = (ResourceDictionary)XamlReader.Parse("""
            <ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
              <Style TargetType="Control"><Setter Property="FontFamily" Value="{DynamicResource UiFont}"/><Setter Property="FontSize" Value="13"/><Setter Property="Foreground" Value="{DynamicResource Ink}"/></Style>
              <Style TargetType="Button" BasedOn="{StaticResource {x:Type Control}}">
                <Setter Property="Background" Value="{DynamicResource Surface2}"/><Setter Property="BorderBrush" Value="{DynamicResource Line}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Cursor" Value="Hand"/>
                <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="frame" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="frame" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="frame" Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
              </Style>
              <Style TargetType="TextBox" BasedOn="{StaticResource {x:Type Control}}"><Setter Property="Background" Value="{DynamicResource Surface2}"/><Setter Property="BorderBrush" Value="{DynamicResource Line}"/><Setter Property="CaretBrush" Value="{DynamicResource Ink}"/><Setter Property="SelectionBrush" Value="{DynamicResource Accent}"/></Style>
              <Style TargetType="PasswordBox" BasedOn="{StaticResource {x:Type Control}}"><Setter Property="Background" Value="{DynamicResource Surface2}"/><Setter Property="BorderBrush" Value="{DynamicResource Line}"/><Setter Property="CaretBrush" Value="{DynamicResource Ink}"/></Style>
              <Style TargetType="ComboBox" BasedOn="{StaticResource {x:Type Control}}">
                <Setter Property="Background" Value="{DynamicResource Surface2}"/><Setter Property="BorderBrush" Value="{DynamicResource Line}"/><Setter Property="Foreground" Value="{DynamicResource Ink}"/>
                <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox"><Grid>
                  <ToggleButton Focusable="False" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" ClickMode="Press" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}">
                    <ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="10,8"><TextBlock Text="▾" Foreground="{DynamicResource Ink}" HorizontalAlignment="Right"/></Border></ControlTemplate></ToggleButton.Template>
                  </ToggleButton>
                  <ContentPresenter Margin="10,6,30,6" IsHitTestVisible="False" VerticalAlignment="Center" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"/>
                  <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False">
                    <Border Background="{DynamicResource Surface1}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="8" MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"><ScrollViewer MaxHeight="{TemplateBinding MaxDropDownHeight}" CanContentScroll="True"><ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer></Border>
                  </Popup>
                </Grid><ControlTemplate.Triggers><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
              </Style>
              <Style TargetType="ComboBoxItem" BasedOn="{StaticResource {x:Type Control}}">
                <Setter Property="Background" Value="{DynamicResource Surface1}"/><Setter Property="Padding" Value="10,8"/>
                <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem"><Border x:Name="item" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter TargetName="item" Property="Background" Value="{DynamicResource Surface2}"/></Trigger><Trigger Property="IsSelected" Value="True"><Setter Property="Foreground" Value="{DynamicResource Accent}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
              </Style>
              <Style TargetType="CheckBox" BasedOn="{StaticResource {x:Type Control}}">
                <Setter Property="Margin" Value="0,5"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox"><DockPanel>
                  <Border DockPanel.Dock="Left" Background="{DynamicResource Surface2}" BorderBrush="{DynamicResource Accent}" BorderThickness="1" CornerRadius="4" Width="18" Height="18" Margin="0,0,9,0"><TextBlock x:Name="mark" Text="✓" Foreground="{DynamicResource Accent}" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/></Border>
                  <ContentPresenter VerticalAlignment="Center"/>
                </DockPanel><ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="mark" Property="Visibility" Value="Visible"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
              </Style>
              <Style TargetType="TabControl" BasedOn="{StaticResource {x:Type Control}}"><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TabControl"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><TabPanel IsItemsHost="True" KeyboardNavigation.TabIndex="1"/>
                <Border Grid.Row="1" Background="{DynamicResource Surface1}" Padding="8"><ContentPresenter x:Name="PART_SelectedContentHost" ContentSource="SelectedContent"/></Border>
              </Grid></ControlTemplate></Setter.Value></Setter></Style>
              <Style TargetType="TabItem" BasedOn="{StaticResource {x:Type Control}}"><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TabItem"><Border x:Name="tab" Background="{DynamicResource Surface2}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="8,8,0,0" Padding="14,9"><ContentPresenter ContentSource="Header" RecognizesAccessKey="True"/></Border><ControlTemplate.Triggers><Trigger Property="IsSelected" Value="True"><Setter TargetName="tab" Property="BorderBrush" Value="{DynamicResource Accent}"/><Setter TargetName="tab" Property="Background" Value="{DynamicResource Surface1}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
              <Style x:Key="FlatTrackButton" TargetType="RepeatButton"><Setter Property="Focusable" Value="False"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="{TemplateBinding Background}"/></ControlTemplate></Setter.Value></Setter></Style>
              <Style TargetType="Slider" BasedOn="{StaticResource {x:Type Control}}">
                <Setter Property="MinHeight" Value="24"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Slider"><Grid Margin="6,0">
                  <Border Height="4" Background="{DynamicResource Surface2}" CornerRadius="2"/>
                  <Track x:Name="PART_Track" Orientation="{TemplateBinding Orientation}" Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}" Value="{Binding Value, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}" IsDirectionReversed="{TemplateBinding IsDirectionReversed}">
                    <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource FlatTrackButton}" Command="Slider.DecreaseLarge" Background="Transparent"/></Track.DecreaseRepeatButton>
                    <Track.Thumb><Thumb Width="12" Height="12"><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="{DynamicResource Accent}" CornerRadius="6"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
                    <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource FlatTrackButton}" Command="Slider.IncreaseLarge" Background="Transparent"/></Track.IncreaseRepeatButton>
                  </Track>
                </Grid></ControlTemplate></Setter.Value></Setter>
              </Style>
              <Style TargetType="ProgressBar">
                <Setter Property="Foreground" Value="{DynamicResource Action}"/><Setter Property="Background" Value="{DynamicResource Surface2}"/><Setter Property="BorderThickness" Value="0"/>
                <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ProgressBar"><Grid>
                  <Border x:Name="PART_Track" Background="{TemplateBinding Background}" CornerRadius="3"/>
                  <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" HorizontalAlignment="Left" CornerRadius="3"/>
                </Grid><ControlTemplate.Triggers><Trigger Property="IsIndeterminate" Value="True"><Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="PART_Indicator" Storyboard.TargetProperty="Opacity" From="0.3" To="1" Duration="0:0:0.7" AutoReverse="True" RepeatBehavior="Forever"/></Storyboard></BeginStoryboard></Trigger.EnterActions></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
              </Style>
              <Style TargetType="ScrollBar">
                <Setter Property="Background" Value="{DynamicResource Surface1}"/><Setter Property="Width" Value="10"/>
                <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar"><Grid Background="{TemplateBinding Background}">
                  <Track x:Name="PART_Track" Orientation="{TemplateBinding Orientation}" Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}" ViewportSize="{TemplateBinding ViewportSize}" Value="{Binding Value, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}" IsDirectionReversed="True">
                    <Track.DecreaseRepeatButton><RepeatButton x:Name="decrease" Style="{StaticResource FlatTrackButton}" Command="ScrollBar.PageUpCommand" Background="Transparent"/></Track.DecreaseRepeatButton>
                    <Track.Thumb><Thumb x:Name="thumb" MinHeight="18"><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="{DynamicResource Muted}" CornerRadius="5" Margin="2"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
                    <Track.IncreaseRepeatButton><RepeatButton x:Name="increase" Style="{StaticResource FlatTrackButton}" Command="ScrollBar.PageDownCommand" Background="Transparent"/></Track.IncreaseRepeatButton>
                  </Track>
                </Grid><ControlTemplate.Triggers><Trigger Property="Orientation" Value="Horizontal"><Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/><Setter TargetName="decrease" Property="Command" Value="ScrollBar.PageLeftCommand"/><Setter TargetName="increase" Property="Command" Value="ScrollBar.PageRightCommand"/><Setter TargetName="thumb" Property="MinHeight" Value="0"/><Setter TargetName="thumb" Property="MinWidth" Value="18"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
                <Style.Triggers><Trigger Property="Orientation" Value="Horizontal"><Setter Property="Width" Value="Auto"/><Setter Property="Height" Value="10"/></Trigger></Style.Triggers>
              </Style>
              <Style TargetType="MenuItem" BasedOn="{StaticResource {x:Type Control}}"><Setter Property="Background" Value="{DynamicResource Surface1}"/><Setter Property="Padding" Value="12,8"/>
                <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="MenuItem"><Border x:Name="menu" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" CornerRadius="6"><ContentPresenter ContentSource="Header" RecognizesAccessKey="True"/></Border><ControlTemplate.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter TargetName="menu" Property="Background" Value="{DynamicResource Surface2}"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
              </Style>
              <Style TargetType="ContextMenu"><Setter Property="Background" Value="{DynamicResource Surface1}"/><Setter Property="Foreground" Value="{DynamicResource Ink}"/></Style>
            </ResourceDictionary>
            """);
        Resources.MergedDictionaries.Add(dictionary);
    }

    void ApplyTheme()
    {
        var light = session.Settings.Appearance == "light";
        string[][] colors =
        [
            ["Surface0", light ? "#F6F3EC" : "#0E0F14"], ["Surface1", light ? "#FFFFFF" : "#171920"],
            ["Surface2", light ? "#EDE9E0" : "#20232B"], ["Line", light ? "#E2DED4" : "#2C2F37"],
            ["Ink", light ? "#0E0F14" : "#F6F3EC"], ["Muted", light ? "#5C6068" : "#8A8F98"],
            ["Accent", light ? "#0B6CB5" : "#3FA9F5"], ["Action", "#3FA9F5"], ["Coral", "#FF6B57"], ["Amber", light ? "#8F5E00" : "#FFC233"],
        ];
        foreach (var pair in colors) { var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(pair[1])); brush.Freeze(); Resources[pair[0]] = brush; }
    }
}
