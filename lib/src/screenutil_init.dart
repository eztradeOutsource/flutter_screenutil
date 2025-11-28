import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import './_flutter_widgets.dart';
import 'screen_util.dart';
import 'screenutil_mixin.dart';

typedef RebuildFactor = bool Function(MediaQueryData old, MediaQueryData data);

typedef ScreenUtilInitBuilder = Widget Function(
  BuildContext context,
  Widget? child,
);

abstract class RebuildFactors {
  static bool size(MediaQueryData old, MediaQueryData data) {
    return old.size != data.size;
  }

  static bool orientation(MediaQueryData old, MediaQueryData data) {
    return old.orientation != data.orientation;
  }

  static bool sizeAndViewInsets(MediaQueryData old, MediaQueryData data) {
    return old.viewInsets != data.viewInsets;
  }

  static bool change(MediaQueryData old, MediaQueryData data) {
    return old != data;
  }

  static bool always(MediaQueryData _, MediaQueryData __) {
    return true;
  }

  static bool none(MediaQueryData _, MediaQueryData __) {
    return false;
  }
}

abstract class FontSizeResolvers {
  static double width(num fontSize, ScreenUtil instance) {
    return instance.setWidth(fontSize);
  }

  static double height(num fontSize, ScreenUtil instance) {
    return instance.setHeight(fontSize);
  }

  static double radius(num fontSize, ScreenUtil instance) {
    return instance.radius(fontSize);
  }

  static double diameter(num fontSize, ScreenUtil instance) {
    return instance.diameter(fontSize);
  }

  static double diagonal(num fontSize, ScreenUtil instance) {
    return instance.diagonal(fontSize);
  }
}

class ScreenUtilInit extends StatefulWidget {
  /// A helper widget that initializes [ScreenUtil]
  const ScreenUtilInit({
    Key? key,
    this.builder,
    this.child,
    this.rebuildFactor = RebuildFactors.size,
    this.designSize = ScreenUtil.defaultSize,
    this.splitScreenMode = false,
    this.minTextAdapt = false,
    this.useInheritedMediaQuery = false,
    this.ensureScreenSize = false,
    this.enableScaleWH,
    this.enableScaleText,
    this.responsiveWidgets,
    this.excludeWidgets,
    this.fontSizeResolver = FontSizeResolvers.width,
  }) : super(key: key);

  final ScreenUtilInitBuilder? builder;
  final Widget? child;
  final bool splitScreenMode;
  final bool minTextAdapt;
  final bool useInheritedMediaQuery;
  final bool ensureScreenSize;
  final bool Function()? enableScaleWH;
  final bool Function()? enableScaleText;
  final RebuildFactor rebuildFactor;
  final FontSizeResolver fontSizeResolver;

  /// The [Size] of the device in the design draft, in dp
  final Size designSize;
  final Iterable<String>? responsiveWidgets;
  final Iterable<String>? excludeWidgets;

  @override
  State<ScreenUtilInit> createState() => _ScreenUtilInitState();
}

class _ScreenUtilInitState extends State<ScreenUtilInit> with WidgetsBindingObserver {
  final _canMarkedToBuild = HashSet<String>();
  final _excludedWidgets = HashSet<String>();
  MediaQueryData? _mediaQueryData;
  final _binding = WidgetsBinding.instance;
  final _screenSizeCompleter = Completer<void>();

  @override
  void initState() {
    if (widget.responsiveWidgets != null) {
      _canMarkedToBuild.addAll(widget.responsiveWidgets!);
    }

    ScreenUtil.enableScale(enableWH: widget.enableScaleWH, enableText: widget.enableScaleText);

    _validateSize().then(_screenSizeCompleter.complete);

    super.initState();
    _binding.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _revalidate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _revalidate();
  }

  MediaQueryData? _newData() {
    final view = View.maybeOf(context);
    if (view != null) {
      return MediaQueryData.fromView(view).copyWith(size: getSizeApp(context).sizeApp);
    }
    return null;
  }

  Future<void> _validateSize() async {
    if (widget.ensureScreenSize) return ScreenUtil.ensureScreenSize();
  }

  void _markNeedsBuildIfAllowed(Element el) {
    final widgetName = el.widget.runtimeType.toString();
    if (_excludedWidgets.contains(widgetName)) return;
    final allowed = widget is SU ||
        _canMarkedToBuild.contains(widgetName) ||
        !(widgetName.startsWith('_') || flutterWidgets.contains(widgetName));

    if (allowed) el.markNeedsBuild();
  }

  void _updateTree(Element el) {
    _markNeedsBuildIfAllowed(el);
    el.visitChildren(_updateTree);
  }

  void _revalidate([void Function()? callback]) {
    final oldData = _mediaQueryData;
    final newData = _newData();

    if (newData == null) return;

    if (oldData == null || widget.rebuildFactor(oldData, newData)) {
      setState(() {
        _mediaQueryData = newData;
        _updateTree(context as Element);
        callback?.call();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = _mediaQueryData;

    if (mq == null) return const SizedBox.shrink();

    if (!widget.ensureScreenSize) {
      ScreenUtil.configure(
        data: mq,
        designSize: widget.designSize,
        splitScreenMode: widget.splitScreenMode,
        minTextAdapt: widget.minTextAdapt,
        fontSizeResolver: widget.fontSizeResolver,
      );

      return widget.builder?.call(context, widget.child) ?? widget.child!;
    }

    return FutureBuilder<void>(
      future: _screenSizeCompleter.future,
      builder: (c, snapshot) {
        ScreenUtil.configure(
          data: mq,
          designSize: widget.designSize,
          splitScreenMode: widget.splitScreenMode,
          minTextAdapt: widget.minTextAdapt,
          fontSizeResolver: widget.fontSizeResolver,
        );

        if (snapshot.connectionState == ConnectionState.done) {
          return widget.builder?.call(context, widget.child) ?? widget.child!;
        }

        return const SizedBox.shrink();
      },
    );
  }

  @override
  void dispose() {
    _binding.removeObserver(this);
    super.dispose();
  }
}

class DeviceSizeApp {
  final bool isMobile;
  final Size sizeApp;
  DeviceSizeApp({required this.isMobile, required this.sizeApp});
}

// Cache kết quả tính toán kích thước ứng dụng
bool? is16by9;
DeviceSizeApp? landscapeSize;
DeviceSizeApp? portraitSize;
double rateScreen = 812 / 375;
double? buffHeight;
double? buffWidth;
bool isFirstCalc = false;
DeviceSizeApp getSizeApp(BuildContext context) {
  final screenWidth = MediaQuery.of(context).size.width;
  final screenHeight = MediaQuery.of(context).size.height;
  final orientation = MediaQuery.of(context).orientation;
  bool isMobile = !((orientation == Orientation.portrait && screenWidth >= 530) ||
          (orientation == Orientation.landscape && screenHeight >= 600)) //)
      ;
  if (isMobile) {
    if (Platform.isIOS) {
      is16by9 ??= (screenHeight / screenWidth - 16 / 9).abs() < 0.05;
      if (is16by9 ?? false) {
        /// tính toán đối với thiết bị chuẩn cũ
        if (orientation == Orientation.portrait) {
          portraitSize ??= DeviceSizeApp(isMobile: isMobile, sizeApp: Size(screenHeight / rateScreen, screenHeight));
          return portraitSize!;
        } else {
          landscapeSize ??= DeviceSizeApp(isMobile: isMobile, sizeApp: Size(screenWidth, screenWidth / rateScreen));
          return landscapeSize!;
        }
      }
    }
    return DeviceSizeApp(isMobile: isMobile, sizeApp: MediaQuery.of(context).size);
  } else {
    if (!isFirstCalc) {
      isFirstCalc = true;
      buffHeight = screenHeight;
      buffWidth = screenHeight / rateScreen;
      if (buffWidth! > screenWidth) {
        buffHeight = screenWidth * rateScreen;
      }
    }
    if (orientation == Orientation.portrait) {
      portraitSize ??= DeviceSizeApp(isMobile: isMobile, sizeApp: Size(buffWidth!, buffHeight!));
      return portraitSize!;
    } else {
      landscapeSize ??= DeviceSizeApp(isMobile: isMobile, sizeApp: Size(buffHeight!, buffWidth!));
      return landscapeSize!;
    }
  }
}
