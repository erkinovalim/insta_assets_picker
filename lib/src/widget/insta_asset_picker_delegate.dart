// ignore_for_file: implementation_imports

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:insta_assets_picker/insta_assets_picker.dart';
import 'package:insta_assets_picker/src/insta_assets_crop_controller.dart';
import 'package:insta_assets_picker/src/widget/crop_viewer.dart';
import 'package:provider/provider.dart';
import 'package:icons_plus/icons_plus.dart';

import 'package:wechat_picker_library/wechat_picker_library.dart';

/// The reduced height of the crop view
const _kReducedCropViewHeight = kToolbarHeight;

/// The position of the crop view when extended
const _kExtendedCropViewPosition = 0.0;

/// Scroll offset multiplier to start viewer position animation
const _kScrollMultiplier = 1.5;

const _kIndicatorSize = 25.0;
const _kPathSelectorRowHeight = 50.0;
const _kActionsPadding = EdgeInsets.symmetric(horizontal: 8, vertical: 8);

typedef InstaPickerActionsBuilder = List<Widget> Function(
  BuildContext context,
  ThemeData pickerTheme,
  double height,
  VoidCallback unselectAll,
);

class InstaAssetPickerBuilder extends DefaultAssetPickerBuilderDelegate {
  InstaAssetPickerBuilder({
    required super.initialPermission,
    required super.provider,
    required this.onCompleted,
    required InstaAssetPickerConfig config,
    super.keepScrollOffset,
    super.locale,
  })  : _cropController =
            InstaAssetsCropController(keepScrollOffset, config.cropDelegate),
        title = config.title,
        closeOnComplete = config.closeOnComplete,
        skipCropOnComplete = config.skipCropOnComplete,
        actionsBuilder = config.actionsBuilder,
        super(
          gridCount: config.gridCount,
          pickerTheme: config.pickerTheme,
          specialItemPosition:
              config.specialItemPosition ?? SpecialItemPosition.none,
          specialItemBuilder: config.specialItemBuilder,
          loadingIndicatorBuilder: config.loadingIndicatorBuilder,
          selectPredicate: config.selectPredicate,
          limitedPermissionOverlayPredicate:
              config.limitedPermissionOverlayPredicate,
          themeColor: config.themeColor,
          textDelegate: config.textDelegate,
          gridThumbnailSize: config.gridThumbnailSize,
          previewThumbnailSize: config.previewThumbnailSize,
          pathNameBuilder: config.pathNameBuilder,
          shouldRevertGrid: false,
          dragToSelect: false, // not yet supported with the inst_picker
        );

  /// The text title in the picker [AppBar].
  final String? title;

  /// Callback called when the assets selection is confirmed.
  /// It will as argument a [Stream] with exportation details [InstaAssetsExportDetails].
  final Function(Stream<InstaAssetsExportDetails>) onCompleted;

  /// The [Widget] to display on top of the assets grid view.
  /// Default is unselect all assets button.
  final InstaPickerActionsBuilder? actionsBuilder;

  /// Should the picker be closed when the selection is confirmed
  ///
  /// Defaults to `false`, like instagram
  final bool closeOnComplete;

  /// Should the picker automatically crop when the selection is confirmed
  ///
  /// Defaults to `false`.
  final bool skipCropOnComplete;

  // LOCAL PARAMETERS

  /// Save last position of the grid view scroll controller
  double _lastScrollOffset = 0.0;
  double _lastEndScrollOffset = 0.0;

  /// Scroll offset position to jump to after crop view is expanded
  double? _scrollTargetOffset;

  final ValueNotifier<double> _cropViewPosition = ValueNotifier<double>(0);
  final _cropViewerKey = GlobalKey<CropViewerState>();

  /// Controller handling the state of asset crop values and the exportation
  final InstaAssetsCropController _cropController;

  /// Whether the picker is mounted. Set to `false` if disposed.
  bool _mounted = true;

  @override
  void dispose() {
    _mounted = false;
    if (!keepScrollOffset) {
      _cropController.dispose();
      _cropViewPosition.dispose();
    }
    super.dispose();
  }

  /// Called when the confirmation [TextButton] is tapped
  void onConfirm(BuildContext context) {
    if (closeOnComplete) {
      Navigator.of(context).pop(provider.selectedAssets);
    }
    _cropViewerKey.currentState?.saveCurrentCropChanges();
    onCompleted(
      _cropController.exportCropFiles(
        provider.selectedAssets,
        skipCrop: skipCropOnComplete,
      ),
    );
  }

  /// The responsive height of the crop view
  /// setup to not be bigger than half the screen height
  double cropViewHeight(BuildContext context) => math.min(
        MediaQuery.of(context).size.width,
        MediaQuery.of(context).size.height * 0.5,
      );

  /// Returns thumbnail [index] position in scroll view
  double indexPosition(BuildContext context, int index) {
    final row = (index / gridCount).floor();
    final size =
        (MediaQuery.of(context).size.width - itemSpacing * (gridCount - 1)) /
            gridCount;
    return row * size + (row * itemSpacing);
  }

  /// Expand the crop view size to the maximum
  void _expandCropView([double? lockOffset]) {
    _scrollTargetOffset = lockOffset;
    _cropViewPosition.value = _kExtendedCropViewPosition;
  }

  /// Unselect all the selected assets
  void unSelectAll() {
    provider.selectedAssets = [];
    _cropController.clear();
  }

  /// Initialize [previewAsset] with [p.selectedAssets] if not empty
  /// otherwise if the first item of the album
  Future<void> _initializePreviewAsset(
    DefaultAssetPickerProvider p,
    bool shouldDisplayAssets,
  ) async {
    if (!_mounted || _cropController.previewAsset.value != null) return;

    if (p.selectedAssets.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_mounted) {
          _cropController.previewAsset.value = p.selectedAssets.last;
        }
      });
    }

    // when asset list is available and no asset is selected,
    // preview the first of the list
    if (shouldDisplayAssets && p.selectedAssets.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final list =
            await p.currentPath?.path.getAssetListRange(start: 0, end: 1);
        if (_mounted && (list?.isNotEmpty ?? false)) {
          _cropController.previewAsset.value = list!.first;
        }
      });
    }
  }

  /// Called when the asset thumbnail is tapped
  final Duration _debounceDuration = Duration(milliseconds: 100);
  DateTime _lastSelectTime =
      DateTime.now().subtract(Duration(milliseconds: 100));

  @override
  Future<void> viewAsset(
    BuildContext context,
    int? index,
    AssetEntity currentAsset,
  ) async {
    if (index == null) return;

    // Debounce: if a selection was made less than _debounceDuration ago, ignore this tap.
    if (DateTime.now().difference(_lastSelectTime) < _debounceDuration) {
      return;
    }
    // Update last selection time.
    _lastSelectTime = DateTime.now();

    if (_cropController.isCropViewReady.value != true) return;

    // If the tapped asset is already the preview asset, unselect it.
    if (provider.selectedAssets.isNotEmpty &&
        _cropController.previewAsset.value == currentAsset) {
      await selectAsset(context, currentAsset, index, true);
      _cropController.previewAsset.value = provider.selectedAssets.isEmpty
          ? currentAsset
          : provider.selectedAssets.last;
      return;
    }

    // Otherwise, update preview asset and select it.
    _cropController.previewAsset.value = currentAsset;
    await selectAsset(context, currentAsset, index, false);
  }

  /// Called when an asset is selected
  @override
  Future<void> selectAsset(
    BuildContext context,
    AssetEntity asset,
    int index,
    bool selected,
  ) async {
    if (_cropController.isCropViewReady.value != true) return;

    if (DateTime.now().difference(_lastSelectTime) < _debounceDuration) {
      return;
    }
    // Update last selection time.
    _lastSelectTime = DateTime.now();

    final thumbnailPosition = indexPosition(context, index);
    final prevCount = provider.selectedAssets.length;

    await super.selectAsset(context, asset, index, selected);

    // Update preview asset based on selection changes.
    final selectedAssets = provider.selectedAssets;
    if (prevCount < selectedAssets.length) {
      _cropController.previewAsset.value = asset;
    } else if (selected &&
        asset == _cropController.previewAsset.value &&
        selectedAssets.isNotEmpty) {
      _cropController.previewAsset.value = selectedAssets.last;
    }

    _expandCropView(thumbnailPosition);
  }

  /// Handle scroll on grid view to hide/expand the crop view
  bool _handleScroll(
    BuildContext context,
    ScrollNotification notification,
    double position,
    double reducedPosition,
  ) {
    final isScrollUp = gridScrollController.position.userScrollDirection ==
        ScrollDirection.reverse;
    final isScrollDown = gridScrollController.position.userScrollDirection ==
        ScrollDirection.forward;

    if (notification is ScrollEndNotification) {
      _lastEndScrollOffset = gridScrollController.offset;
      // reduce crop view
      if (position > reducedPosition && position < _kExtendedCropViewPosition) {
        _cropViewPosition.value = reducedPosition;
        return true;
      }
    }

    // expand crop view
    if (isScrollDown &&
        gridScrollController.offset <= 0 &&
        position < _kExtendedCropViewPosition) {
      // if scroll at edge, compute position based on scroll
      if (_lastScrollOffset > gridScrollController.offset) {
        _cropViewPosition.value -=
            (_lastScrollOffset.abs() - gridScrollController.offset.abs()) * 6;
      } else {
        // otherwise just expand it
        _expandCropView();
      }
    } else if (isScrollUp &&
        (gridScrollController.offset - _lastEndScrollOffset) *
                _kScrollMultiplier >
            cropViewHeight(context) - position &&
        position > reducedPosition) {
      // reduce crop view
      _cropViewPosition.value = cropViewHeight(context) -
          (gridScrollController.offset - _lastEndScrollOffset) *
              _kScrollMultiplier;
    }

    _lastScrollOffset = gridScrollController.offset;

    return true;
  }

  /// Returns a loader [Widget] to show in crop view and instead of confirm button
  Widget _buildLoader(BuildContext context, double radius) {
    if (super.loadingIndicatorBuilder != null) {
      return super.loadingIndicatorBuilder!(context, provider.isAssetsEmpty);
    }
    return PlatformProgressIndicator(
      radius: radius,
      size: radius * 2,
      color: theme.iconTheme.color,
    );
  }

  /// Returns the [TextButton] that open album list
  @override
  Widget pathEntitySelector(BuildContext context) {
    Widget selector(BuildContext context) {
      return TextButton(
        style: TextButton.styleFrom(
          foregroundColor: theme.splashColor,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(4),
        ),
        onPressed: () {
          Feedback.forTap(context);
          isSwitchingPath.value = !isSwitchingPath.value;
        },
        child:
            Selector<DefaultAssetPickerProvider, PathWrapper<AssetPathEntity>?>(
          selector: (_, DefaultAssetPickerProvider p) => p.currentPath,
          builder: (_, PathWrapper<AssetPathEntity>? p, Widget? w) => Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (p != null)
                Flexible(
                  child: Text(
                    isPermissionLimited && p.path.isAll
                        ? textDelegate.accessiblePathName
                        : pathNameBuilder?.call(p.path) ?? p.path.name,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              w!,
            ],
          ),
          child: ValueListenableBuilder<bool>(
            valueListenable: isSwitchingPath,
            builder: (_, bool isSwitchingPath, Widget? w) => Transform.rotate(
              angle: isSwitchingPath ? math.pi : 0,
              child: w,
            ),
            child: Icon(
              Icons.keyboard_arrow_down,
              size: 20,
              color: theme.iconTheme.color,
            ),
          ),
        ),
      );
    }

    return ChangeNotifierProvider<DefaultAssetPickerProvider>.value(
      value: provider,
      builder: (BuildContext c, _) => selector(c),
    );
  }

  /// Returns the list ofactions that are displayed on top of the assets grid view
  Widget _buildActions(BuildContext context) {
    final double height = _kPathSelectorRowHeight - _kActionsPadding.vertical;
    final ThemeData actionTheme = theme.copyWith(
      buttonTheme: const ButtonThemeData(padding: EdgeInsets.all(8)),
    );

    return SizedBox(
      height: _kPathSelectorRowHeight,
      width: MediaQuery.of(context).size.width,
      child: Padding(
        // decrease left padding because the path selector button has a padding
        padding: _kActionsPadding.copyWith(left: _kActionsPadding.left - 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            pathEntitySelector(context),
            actionsBuilder != null
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: actionsBuilder!(
                      context,
                      actionTheme,
                      height,
                      unSelectAll,
                    ),
                  )
                : InstaPickerCircleIconButton.unselectAll(
                    onTap: unSelectAll,
                    theme: actionTheme,
                    size: height,
                  ),
          ],
        ),
      ),
    );
  }

  /// Returns the top right selection confirmation [TextButton]
  /// Calls [onConfirm]
  @override
  Widget confirmButton(BuildContext context) {
    final Widget button = ValueListenableBuilder<bool>(
      valueListenable: _cropController.isCropViewReady,
      builder: (_, isLoaded, __) => Consumer<DefaultAssetPickerProvider>(
        builder: (_, DefaultAssetPickerProvider p, __) {
          return Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: ClipOval(
              child: AspectRatio(
                aspectRatio: 1,
                child: CupertinoButton(
                  padding: EdgeInsets.zero,
                  child: isLoaded
                      ? Icon(
                          CupertinoIcons.check_mark_circled,
                          color: isLoaded && p.isSelectedNotEmpty
                              ? CupertinoColors.activeBlue
                              : CupertinoColors.inactiveGray,
                          size: 26,
                        )
                      // Text(
                      //     String.fromCharCode(
                      //         CupertinoIcons.check_mark_circled.codePoint),
                      //     style: TextStyle(
                      //       inherit: false,
                      //       color: CupertinoColors.activeBlue,
                      //       fontSize: 26.0,
                      //       fontWeight: FontWeight.w500,
                      //       fontFamily:
                      //           CupertinoIcons.check_mark_circled.fontFamily,
                      //       package:
                      //           CupertinoIcons.check_mark_circled.fontPackage,
                      //     ),
                      //   )
                      : _buildLoader(context, 10),
                  onPressed: isLoaded && p.isSelectedNotEmpty
                      ? () => onConfirm(context)
                      : null,
                ),
              ),
            ),
          );
        },
      ),
    );
    return ChangeNotifierProvider<DefaultAssetPickerProvider>.value(
      value: provider,
      builder: (_, __) => button,
    );
  }

  /// Returns most of the widgets of the layout, the app bar, the crop view and the grid view
  @override
  Widget androidLayout(BuildContext context) {
    // height of appbar + cropview + path selector row
    final topWidgetHeight = cropViewHeight(context) +
        kMinInteractiveDimensionCupertino +
        _kPathSelectorRowHeight +
        MediaQuery.of(context).padding.top;

    return ChangeNotifierProvider<DefaultAssetPickerProvider>.value(
      value: provider,
      builder: (context, _) => ValueListenableBuilder<double>(
          valueListenable: _cropViewPosition,
          builder: (context, position, child) {
            // the top position when the crop view is reduced
            final topReducedPosition = -(cropViewHeight(context) -
                _kReducedCropViewHeight +
                kToolbarHeight);
            position =
                position.clamp(topReducedPosition, _kExtendedCropViewPosition);
            // the height of the crop view visible on screen
            final cropViewVisibleHeight = (topWidgetHeight +
                    position -
                    MediaQuery.of(context).padding.top -
                    kToolbarHeight -
                    _kPathSelectorRowHeight)
                .clamp(_kReducedCropViewHeight, topWidgetHeight);
            // opacity is calculated based on the position of the crop view
            final opacity =
                ((position / -topReducedPosition) + 1).clamp(0.4, 1.0);
            final animationDuration = position == topReducedPosition ||
                    position == _kExtendedCropViewPosition
                ? const Duration(milliseconds: 250)
                : Duration.zero;

            double gridHeight = MediaQuery.of(context).size.height -
                kToolbarHeight -
                _kReducedCropViewHeight;
            // when not assets are displayed, compute the exact height to show the loader
            if (!provider.hasAssetsToDisplay) {
              gridHeight -= cropViewHeight(context) - -_cropViewPosition.value;
            }
            final topPadding = topWidgetHeight + position;
            if (gridScrollController.hasClients &&
                _scrollTargetOffset != null) {
              gridScrollController.jumpTo(_scrollTargetOffset!);
            }
            _scrollTargetOffset = null;

            return Stack(
              children: [
                AnimatedPadding(
                  padding: EdgeInsets.only(top: topPadding),
                  duration: animationDuration,
                  child: SizedBox(
                    height: gridHeight,
                    width: MediaQuery.of(context).size.width,
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (notification) => _handleScroll(
                        context,
                        notification,
                        position,
                        topReducedPosition,
                      ),
                      child: _buildGrid(context),
                    ),
                  ),
                ),
                AnimatedPositioned(
                  top: position,
                  duration: animationDuration,
                  child: SizedBox(
                    width: MediaQuery.of(context).size.width,
                    height: topWidgetHeight,
                    child: AssetPickerAppBarWrapper(
                      appBar: CupertinoNavigationBar(
                        padding: EdgeInsetsDirectional.fromSTEB(0, 0, 8, 0),
                        leading: CupertinoNavigationBarBackButton(
                          color: CupertinoColors.activeBlue,
                          previousPageTitle: 'Продукты',
                        ),
                        transitionBetweenRoutes: false,
                        middle: title != null
                            ? Text(
                                title!,
                                style: theme.appBarTheme.titleTextStyle,
                              )
                            : null,
                        trailing: confirmButton(context),
                      ),
                      body: DecoratedBox(
                        decoration: BoxDecoration(
                          color: pickerTheme?.canvasColor,
                        ),
                        child: Column(
                          children: [
                            Listener(
                              onPointerDown: (_) {
                                _expandCropView();
                                // stop scroll event
                                if (gridScrollController.hasClients) {
                                  gridScrollController
                                      .jumpTo(gridScrollController.offset);
                                }
                              },
                              child: CropViewer(
                                key: _cropViewerKey,
                                controller: _cropController,
                                textDelegate: textDelegate,
                                provider: provider,
                                opacity: opacity,
                                height: cropViewHeight(context),
                                // center the loader in the visible viewport of the crop view
                                loaderWidget: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: SizedBox(
                                    height: cropViewVisibleHeight,
                                    child: Center(
                                      child: _buildLoader(context, 16),
                                    ),
                                  ),
                                ),
                                theme: theme,
                              ),
                            ),
                            _buildActions(context),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                pathEntityListBackdrop(context),
                _buildListAlbums(context),
              ],
            );
          }),
    );
  }

  /// Since the layout is the same on all platform, it simply call [androidLayout]
  @override
  Widget appleOSLayout(BuildContext context) => androidLayout(context);

  /// Returns the [ListView] containing the albums
  Widget _buildListAlbums(context) {
    return Consumer<DefaultAssetPickerProvider>(
        builder: (BuildContext context, provider, __) {
      if (isAppleOS(context)) return pathEntityListWidget(context);

      // NOTE: fix position on android, quite hacky could be optimized
      return ValueListenableBuilder<bool>(
        valueListenable: isSwitchingPath,
        builder: (_, bool isSwitchingPath, Widget? child) =>
            Transform.translate(
          offset: isSwitchingPath
              ? Offset(0, kToolbarHeight + MediaQuery.of(context).padding.top)
              : Offset.zero,
          child: Stack(
            children: [pathEntityListWidget(context)],
          ),
        ),
      );
    });
  }

  @override
  Widget pathEntityListWidget(BuildContext context) {
    appBarPreferredSize ??= appBar(context).preferredSize;
    return Positioned.fill(
      top: isAppleOS(context)
          ? context.topPadding + kMinInteractiveDimensionCupertino
          : 0,
      bottom:
          null, // set this to 0 and remove top: parameter to make this look like a bottom sheet but be careful to place a limit to height
      child: ValueListenableBuilder<bool>(
        valueListenable: isSwitchingPath,
        builder: (_, bool isSwitchingPath, Widget? child) => Semantics(
          hidden: isSwitchingPath ? null : true,
          child: AnimatedAlign(
            duration: switchingPathDuration,
            curve: switchingPathCurve,
            alignment: Alignment.bottomCenter,
            heightFactor: isSwitchingPath ? 1 : 0,
            child: AnimatedOpacity(
              duration: switchingPathDuration,
              curve: switchingPathCurve,
              opacity: !isAppleOS(context) || isSwitchingPath ? 1 : 0,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(10),
                ),
                child: Container(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height *
                        (isAppleOS(context) ? .6 : .8),
                  ),
                  color: theme.colorScheme.background,
                  child: child,
                ),
              ),
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ValueListenableBuilder<PermissionState>(
              valueListenable: permissionNotifier,
              builder: (_, PermissionState ps, Widget? child) => Semantics(
                label: '${semanticsTextDelegate.viewingLimitedAssetsTip}, '
                    '${semanticsTextDelegate.changeAccessibleLimitedAssets}',
                button: true,
                onTap: PhotoManager.presentLimited,
                hidden: !isPermissionLimited,
                focusable: isPermissionLimited,
                excludeSemantics: true,
                child: isPermissionLimited ? child : const SizedBox.shrink(),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                child: Text.rich(
                  TextSpan(
                    children: <TextSpan>[
                      TextSpan(
                        text: textDelegate.viewingLimitedAssetsTip,
                      ),
                      TextSpan(
                        text: ' '
                            '${textDelegate.changeAccessibleLimitedAssets}',
                        style: TextStyle(color: interactiveTextColor(context)),
                        recognizer: TapGestureRecognizer()
                          ..onTap = PhotoManager.presentLimited,
                      ),
                    ],
                  ),
                  style: context.textTheme.bodySmall?.copyWith(fontSize: 14),
                ),
              ),
            ),
            Flexible(
              child: Selector<DefaultAssetPickerProvider,
                  List<PathWrapper<AssetPathEntity>>>(
                selector: (_, DefaultAssetPickerProvider p) => p.paths,
                builder: (_, List<PathWrapper<AssetPathEntity>> paths, __) {
                  final List<PathWrapper<AssetPathEntity>> filtered = paths
                      .where(
                        (PathWrapper<AssetPathEntity> p) => p.assetCount != 0,
                      )
                      .toList();
                  return ListView.separated(
                    padding: const EdgeInsetsDirectional.only(top: 1),
                    shrinkWrap: true,
                    itemCount: filtered.length,
                    itemBuilder: (BuildContext c, int i) => pathEntityWidget(
                      context: c,
                      list: filtered,
                      index: i,
                    ),
                    separatorBuilder: (_, __) => Container(
                      margin: const EdgeInsetsDirectional.only(start: 60),
                      height: 1,
                      color: Colors.grey[400],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget pathEntityWidget({
    required BuildContext context,
    required List<PathWrapper<AssetPathEntity>> list,
    required int index,
  }) {
    final PathWrapper<AssetPathEntity> wrapper = list[index];
    final AssetPathEntity pathEntity = wrapper.path;
    final Uint8List? data = wrapper.thumbnailData;

    Widget builder() {
      if (data != null) {
        return Image.memory(data, fit: BoxFit.cover);
      }
      if (pathEntity.type.containsAudio()) {
        return ColoredBox(
          color: theme.colorScheme.primary.withOpacity(0.12),
          child: const Center(child: Icon(Icons.audiotrack)),
        );
      }
      return ColoredBox(color: theme.colorScheme.primary.withOpacity(0.12));
    }

    final String pathName =
        pathNameBuilder?.call(pathEntity) ?? pathEntity.name;
    final String name = isPermissionLimited && pathEntity.isAll
        ? textDelegate.accessiblePathName
        : pathName;
    final String semanticsName = isPermissionLimited && pathEntity.isAll
        ? semanticsTextDelegate.accessiblePathName
        : pathName;
    final String? semanticsCount = wrapper.assetCount?.toString();
    final StringBuffer labelBuffer = StringBuffer(
      '$semanticsName, ${semanticsTextDelegate.sUnitAssetCountLabel}',
    );
    if (semanticsCount != null) {
      labelBuffer.write(': $semanticsCount');
    }
    return Selector<DefaultAssetPickerProvider, PathWrapper<AssetPathEntity>?>(
      selector: (_, DefaultAssetPickerProvider p) => p.currentPath,
      builder: (_, PathWrapper<AssetPathEntity>? currentWrapper, __) {
        final bool isSelected = currentWrapper?.path == pathEntity;
        return Semantics(
          label: labelBuffer.toString(),
          selected: isSelected,
          onTapHint: semanticsTextDelegate.sActionSwitchPathLabel,
          button: false,
          child: Material(
            color: Colors.white,
            child: InkWell(
              splashFactory: InkSplash.splashFactory,
              onTap: () {
                Feedback.forTap(context);
                context.read<DefaultAssetPickerProvider>().switchPath(wrapper);
                isSwitchingPath.value = false;
                gridScrollController.jumpTo(0);
              },
              child: SizedBox(
                height: isAppleOS(context) ? 64 : 52,
                child: Row(
                  children: <Widget>[
                    RepaintBoundary(
                      child: AspectRatio(aspectRatio: 1, child: builder()),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: 15,
                          end: 20,
                        ),
                        child: ExcludeSemantics(
                          child: ScaleText.rich(
                            [
                              TextSpan(
                                text: name,
                                style: TextStyle(color: Colors.black),
                              ),
                              if (semanticsCount != null)
                                TextSpan(
                                  text: ' ($semanticsCount)',
                                  style: TextStyle(color: Colors.black),
                                ),
                            ],
                            style: const TextStyle(fontSize: 17),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                    if (isSelected)
                      AspectRatio(
                        aspectRatio: 1,
                        child: Icon(
                          CupertinoIcons.check_mark_circled,
                          color: themeColor,
                          size: 26,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Returns the [GridView] displaying the assets
  Widget _buildGrid(BuildContext context) {
    return Consumer<DefaultAssetPickerProvider>(
      builder: (BuildContext context, DefaultAssetPickerProvider p, __) {
        final bool shouldDisplayAssets =
            p.hasAssetsToDisplay || shouldBuildSpecialItem;
        _initializePreviewAsset(p, shouldDisplayAssets);

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: shouldDisplayAssets
              ? MediaQuery(
                  // fix: https://github.com/fluttercandies/flutter_wechat_assets_picker/issues/395
                  data: MediaQuery.of(context).copyWith(
                    padding: const EdgeInsets.only(top: -kToolbarHeight),
                  ),
                  child: RepaintBoundary(child: assetsGridBuilder(context)),
                )
              : loadingIndicator(context),
        );
      },
    );
  }

  /// To show selected assets indicator and preview asset overlay
  @override
  Widget selectIndicator(BuildContext context, int index, AssetEntity asset) {
    final selectedAssets = provider.selectedAssets;
    final Duration duration = switchingPathDuration * 0.75;

    final int indexSelected = selectedAssets.indexOf(asset);
    final bool isSelected = indexSelected != -1;

    final Widget innerSelector = AnimatedContainer(
      duration: duration,
      width: _kIndicatorSize,
      height: _kIndicatorSize,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(color: Colors.black26, blurRadius: 4, spreadRadius: 1)
        ],
        border: isSelected
            ? null
            : Border.all(color: theme.unselectedWidgetColor, width: 1.0),
        color: isSelected
            ? themeColor
            : theme.unselectedWidgetColor.withValues(alpha: .2),
        shape: BoxShape.circle,
      ),
      child: FittedBox(
        child: AnimatedSwitcher(
          duration: duration,
          reverseDuration: duration,
          child: isSelected
              ? Text((indexSelected + 1).toString())
              : const SizedBox.shrink(),
        ),
      ),
    );

    return ValueListenableBuilder<AssetEntity?>(
      valueListenable: _cropController.previewAsset,
      builder: (context, previewAsset, child) {
        final bool isPreview = asset == _cropController.previewAsset.value;

        return Positioned.fill(
          child: GestureDetector(
            onTap: isPreviewEnabled
                ? () => selectAsset(context, asset, index, isSelected)
                : null,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Align(
                alignment: AlignmentDirectional.topEnd,
                child: innerSelector,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget selectedBackdrop(BuildContext context, int index, AssetEntity asset) {
    final double indicatorSize =
        MediaQuery.sizeOf(context).width / gridCount / 3;
    return Positioned.fill(
      child: GestureDetector(
        onTap: isPreviewEnabled
            ? () {
                viewAsset(context, index, asset);
              }
            : null,
        child: Consumer<DefaultAssetPickerProvider>(
          builder: (_, DefaultAssetPickerProvider p, __) {
            final int index = p.selectedAssets.indexOf(asset);
            final bool selected = index != -1;
            return AnimatedContainer(
              duration: switchingPathDuration,
              padding: EdgeInsets.all(indicatorSize * .35),
              color: selected ? Colors.white.withValues(alpha: 0.5) : null,
            );
          },
        ),
      ),
    );
  }

  /// Disable item banned indicator in single mode (#26) so that
  /// the new selected asset replace the old one
  @override
  Widget itemBannedIndicator(BuildContext context, AssetEntity asset) =>
      isSingleAssetMode
          ? const SizedBox.shrink()
          : super.itemBannedIndicator(context, asset);
}

// optimized by Claude, need to check the code.
//

// ignore_for_file: implementation_imports

// import 'dart:math' as math;
// import 'dart:typed_data';

// import 'package:flutter/gestures.dart';
// import 'package:flutter/material.dart';
// import 'package:flutter/cupertino.dart';
// import 'package:flutter/rendering.dart';
// import 'package:insta_assets_picker/insta_assets_picker.dart';
// import 'package:insta_assets_picker/src/insta_assets_crop_controller.dart';
// import 'package:insta_assets_picker/src/widget/crop_viewer.dart';
// import 'package:provider/provider.dart';
// import 'package:icons_plus/icons_plus.dart';

// import 'package:wechat_picker_library/wechat_picker_library.dart';

// // Constants
// const _kReducedCropViewHeight = kToolbarHeight;
// const _kExtendedCropViewPosition = 0.0;
// const _kScrollMultiplier = 1.5;
// const _kIndicatorSize = 25.0;
// const _kPathSelectorRowHeight = 50.0;
// const _kActionsPadding = EdgeInsets.symmetric(horizontal: 8, vertical: 8);
// const _kDebounceMilliseconds = 100;

// typedef InstaPickerActionsBuilder = List<Widget> Function(
//   BuildContext context,
//   ThemeData? pickerTheme,
//   double height,
//   VoidCallback unselectAll,
// );

// class InstaAssetPickerBuilder extends DefaultAssetPickerBuilderDelegate {
//   InstaAssetPickerBuilder({
//     required super.initialPermission,
//     required super.provider,
//     required this.onCompleted,
//     required InstaAssetPickerConfig config,
//     super.keepScrollOffset,
//     super.locale,
//   })  : _cropController =
//             InstaAssetsCropController(keepScrollOffset, config.cropDelegate),
//         title = config.title,
//         closeOnComplete = config.closeOnComplete,
//         skipCropOnComplete = config.skipCropOnComplete,
//         actionsBuilder = config.actionsBuilder,
//         super(
//           gridCount: config.gridCount,
//           pickerTheme: config.pickerTheme,
//           specialItemPosition:
//               config.specialItemPosition ?? SpecialItemPosition.none,
//           specialItemBuilder: config.specialItemBuilder,
//           loadingIndicatorBuilder: config.loadingIndicatorBuilder,
//           selectPredicate: config.selectPredicate,
//           limitedPermissionOverlayPredicate:
//               config.limitedPermissionOverlayPredicate,
//           themeColor: config.themeColor,
//           textDelegate: config.textDelegate,
//           gridThumbnailSize: config.gridThumbnailSize,
//           previewThumbnailSize: config.previewThumbnailSize,
//           pathNameBuilder: config.pathNameBuilder,
//           shouldRevertGrid: false,
//         );

//   // Properties
//   final String? title;
//   final Function(Stream<InstaAssetsExportDetails>) onCompleted;
//   final InstaPickerActionsBuilder? actionsBuilder;
//   final bool closeOnComplete;
//   final bool skipCropOnComplete;

//   // Private fields
//   double _lastScrollOffset = 0.0;
//   double _lastEndScrollOffset = 0.0;
//   double? _scrollTargetOffset;
//   final ValueNotifier<double> _cropViewPosition = ValueNotifier<double>(0);
//   final _cropViewerKey = GlobalKey<CropViewerState>();
//   final InstaAssetsCropController _cropController;
//   bool _mounted = true;
//   DateTime _lastSelectTime = DateTime.now().subtract(const Duration(milliseconds: _kDebounceMilliseconds));
//   final Duration _debounceDuration = const Duration(milliseconds: _kDebounceMilliseconds);

//   @override
//   void dispose() {
//     _mounted = false;
//     if (!keepScrollOffset) {
//       _cropController.dispose();
//       _cropViewPosition.dispose();
//     }
//     super.dispose();
//   }

//   // Simplified confirm handler
//   void onConfirm(BuildContext context) {
//     _cropViewerKey.currentState?.saveCurrentCropChanges();
    
//     onCompleted(
//       _cropController.exportCropFiles(
//         provider.selectedAssets,
//         skipCrop: skipCropOnComplete,
//       ),
//     );

//     if (closeOnComplete) {
//       Navigator.of(context).pop(provider.selectedAssets);
//     }
//   }

//   // Compute crop view height only once per layout
//   double cropViewHeight(BuildContext context) => math.min(
//         MediaQuery.of(context).size.width,
//         MediaQuery.of(context).size.height * 0.5,
//       );

//   // Calculate index position more efficiently
//   double indexPosition(BuildContext context, int index) {
//     final row = (index / gridCount).floor();
//     final size = (MediaQuery.of(context).size.width - itemSpacing * (gridCount - 1)) / gridCount;
//     return row * (size + itemSpacing);
//   }

//   // Expand crop view
//   void _expandCropView([double? lockOffset]) {
//     _scrollTargetOffset = lockOffset;
//     _cropViewPosition.value = _kExtendedCropViewPosition;
//   }

//   // Unselect all assets
//   void unSelectAll() {
//     provider.selectedAssets = [];
//     _cropController.clear();
//   }

//   // Initialize preview asset more efficiently
//   Future<void> _initializePreviewAsset(
//     DefaultAssetPickerProvider p,
//     bool shouldDisplayAssets,
//   ) async {
//     if (!_mounted || _cropController.previewAsset.value != null) return;

//     if (p.selectedAssets.isNotEmpty) {
//       WidgetsBinding.instance.addPostFrameCallback((_) {
//         if (_mounted) {
//           _cropController.previewAsset.value = p.selectedAssets.last;
//         }
//       });
//       return;
//     }

//     // Only load first asset if needed
//     if (shouldDisplayAssets) {
//       WidgetsBinding.instance.addPostFrameCallback((_) async {
//         final path = p.currentPath?.path;
//         if (path != null) {
//           final list = await path.getAssetListRange(start: 0, end: 1);
//           if (_mounted && (list?.isNotEmpty ?? false)) {
//             _cropController.previewAsset.value = list!.first;
//           }
//         }
//       });
//     }
//   }

//   // Debounced asset viewing
//   @override
//   Future<void> viewAsset(
//     BuildContext context,
//     int? index,
//     AssetEntity currentAsset,
//   ) async {
//     if (index == null) return;
//     if (!_isDebounceExpired()) return;
//     if (_cropController.isCropViewReady.value != true) return;

//     // If the tapped asset is already the preview asset
//     if (provider.selectedAssets.isNotEmpty &&
//         _cropController.previewAsset.value == currentAsset) {
//       await selectAsset(context, currentAsset, index, true);
//       _cropController.previewAsset.value = provider.selectedAssets.isEmpty
//           ? currentAsset
//           : provider.selectedAssets.last;
//       return;
//     }

//     // Update preview and select
//     _cropController.previewAsset.value = currentAsset;
//     await selectAsset(context, currentAsset, index, false);
//   }

//   // Check if debounce period has expired
//   bool _isDebounceExpired() {
//     final now = DateTime.now();
//     if (now.difference(_lastSelectTime) < _debounceDuration) {
//       return false;
//     }
//     _lastSelectTime = now;
//     return true;
//   }

//   // Optimized asset selection
//   @override
//   Future<void> selectAsset(
//     BuildContext context,
//     AssetEntity asset,
//     int index,
//     bool selected,
//   ) async {
//     if (_cropController.isCropViewReady.value != true) return;
//     if (!_isDebounceExpired()) return;

//     final thumbnailPosition = indexPosition(context, index);
//     final prevCount = provider.selectedAssets.length;

//     await super.selectAsset(context, asset, index, selected);

//     // Update preview asset efficiently
//     final selectedAssets = provider.selectedAssets;
//     if (prevCount < selectedAssets.length) {
//       _cropController.previewAsset.value = asset;
//     } else if (selected &&
//         asset == _cropController.previewAsset.value &&
//         selectedAssets.isNotEmpty) {
//       _cropController.previewAsset.value = selectedAssets.last;
//     }

//     _expandCropView(thumbnailPosition);
//   }

//   // Optimized scroll handling
//   bool _handleScroll(
//     BuildContext context,
//     ScrollNotification notification,
//     double position,
//     double reducedPosition,
//   ) {
//     final scrollDirection = gridScrollController.position.userScrollDirection;
//     final isScrollUp = scrollDirection == ScrollDirection.reverse;
//     final isScrollDown = scrollDirection == ScrollDirection.forward;

//     if (notification is ScrollEndNotification) {
//       _lastEndScrollOffset = gridScrollController.offset;
//       // Reduce crop view
//       if (position > reducedPosition && position < _kExtendedCropViewPosition) {
//         _cropViewPosition.value = reducedPosition;
//         return true;
//       }
//     }

//     // Expand crop view
//     if (isScrollDown && gridScrollController.offset <= 0 && position < _kExtendedCropViewPosition) {
//       // Compute position based on scroll
//       if (_lastScrollOffset > gridScrollController.offset) {
//         _cropViewPosition.value -= (_lastScrollOffset - gridScrollController.offset) * 6;
//       } else {
//         _expandCropView();
//       }
//     } else if (isScrollUp &&
//         (gridScrollController.offset - _lastEndScrollOffset) * _kScrollMultiplier >
//             cropViewHeight(context) - position &&
//         position > reducedPosition) {
//       // Reduce crop view
//       _cropViewPosition.value = cropViewHeight(context) -
//           (gridScrollController.offset - _lastEndScrollOffset) * _kScrollMultiplier;
//     }

//     _lastScrollOffset = gridScrollController.offset;
//     return true;
//   }

//   // Simplified loader builder
//   Widget _buildLoader(BuildContext context, double radius) {
//     if (super.loadingIndicatorBuilder != null) {
//       return super.loadingIndicatorBuilder!(context, provider.isAssetsEmpty);
//     }
//     return PlatformProgressIndicator(
//       radius: radius,
//       size: radius * 2,
//       color: theme.iconTheme.color,
//     );
//   }

//   // Path entity selector
//   @override
//   Widget pathEntitySelector(BuildContext context) {
//     return ChangeNotifierProvider<DefaultAssetPickerProvider>.value(
//       value: provider,
//       builder: (BuildContext c, _) => TextButton(
//         style: TextButton.styleFrom(
//           foregroundColor: theme.splashColor,
//           tapTargetSize: MaterialTapTargetSize.shrinkWrap,
//           visualDensity: VisualDensity.compact,
//           padding: const EdgeInsets.all(4),
//         ),
//         onPressed: () {
//           Feedback.forTap(context);
//           isSwitchingPath.value = !isSwitchingPath.value;
//         },
//         child: Selector<DefaultAssetPickerProvider, PathWrapper<AssetPathEntity>?>(
//           selector: (_, DefaultAssetPickerProvider p) => p.currentPath,
//           builder: (_, PathWrapper<AssetPathEntity>? p, Widget? w) => Row(
//             mainAxisSize: MainAxisSize.min,
//             children: <Widget>[
//               if (p != null)
//                 Flexible(
//                   child: Text(
//                     isPermissionLimited && p.path.isAll
//                         ? textDelegate.accessiblePathName
//                         : pathNameBuilder?.call(p.path) ?? p.path.name,
//                     style: theme.textTheme.bodyLarge?.copyWith(
//                       fontSize: 16,
//                       fontWeight: FontWeight.bold,
//                     ),
//                     maxLines: 1,
//                     overflow: TextOverflow.ellipsis,
//                   ),
//                 ),
//               w!,
//             ],
//           ),
//           child: ValueListenableBuilder<bool>(
//             valueListenable: isSwitchingPath,
//             builder: (_, bool isSwitchingPath, Widget? w) => Transform.rotate(
//               angle: isSwitchingPath ? math.pi : 0,
//               child: w,
//             ),
//             child: Icon(
//               Icons.keyboard_arrow_down,
//               size: 20,
//               color: theme.iconTheme.color,
//             ),
//           ),
//         ),
//       ),
//     );
//   }

//   // Actions builder
//   Widget _buildActions(BuildContext context) {
//     final double height = _kPathSelectorRowHeight - _kActionsPadding.vertical;
//     final ThemeData? theme = pickerTheme?.copyWith(
//       buttonTheme: const ButtonThemeData(padding: EdgeInsets.all(8)),
//     );

//     return SizedBox(
//       height: _kPathSelectorRowHeight,
//       width: MediaQuery.of(context).size.width,
//       child: Padding(
//         padding: _kActionsPadding.copyWith(left: _kActionsPadding.left - 4),
//         child: Row(
//           mainAxisAlignment: MainAxisAlignment.spaceBetween,
//           children: [
//             pathEntitySelector(context),
//             actionsBuilder != null
//                 ? Row(
//                     mainAxisSize: MainAxisSize.min,
//                     children: actionsBuilder!(
//                       context,
//                       theme,
//                       height,
//                       unSelectAll,
//                     ),
//                   )
//                 : InstaPickerCircleIconButton.unselectAll(
//                     onTap: unSelectAll,
//                     theme: theme,
//                     size: height,
//                   ),
//           ],
//         ),
//       ),
//     );
//   }

//   // Confirm button with optimized rebuild logic
//   @override
//   Widget confirmButton(BuildContext context) {
//     return ChangeNotifierProvider<DefaultAssetPickerProvider>.value(
//       value: provider,
//       builder: (_, __) => ValueListenableBuilder<bool>(
//         valueListenable: _cropController.isCropViewReady,
//         builder: (_, isLoaded, __) => Consumer<DefaultAssetPickerProvider>(
//           builder: (_, DefaultAssetPickerProvider p, __) {
//             final bool canConfirm = isLoaded && p.isSelectedNotEmpty;
//             return Padding(
//               padding: const EdgeInsets.symmetric(vertical: 6),
//               child: ClipOval(
//                 child: AspectRatio(
//                   aspectRatio: 1,
//                   child: CupertinoButton(
//                     padding: EdgeInsets.zero,
//                     child: isLoaded
//                         ? Icon(
//                             CupertinoIcons.check_mark_circled,
//                             color: canConfirm
//                                 ? CupertinoColors.activeBlue
//                                 : CupertinoColors.inactiveGray,
//                             size: 26,
//                           )
//                         : _buildLoader(context, 10),
//                     onPressed: canConfirm ? () => onConfirm(context) : null,
//                   ),
//                 ),
//               ),
//             );
//           },
//         ),
//       ),
//     );
//   }

//   // Optimized layout
//   @override
//   Widget androidLayout(BuildContext context) {
//     // Precalculate static dimensions
//     final MediaQueryData mediaQuery = MediaQuery.of(context);
//     final double topPadding = mediaQuery.padding.top;
//     final double screenWidth = mediaQuery.size.width;
    
//     // Calculate crop view height once
//     final double baseCropViewHeight = cropViewHeight(context);
    
//     final double topWidgetHeight = baseCropViewHeight +
//         kMinInteractiveDimensionCupertino +
//         _kPathSelectorRowHeight +
//         topPadding;

//     return ChangeNotifierProvider<DefaultAssetPickerProvider>.value(
//       value: provider,
//       builder: (context, _) => ValueListenableBuilder<double>(
//         valueListenable: _cropViewPosition,
//         builder: (context, position, _) {
//           // Calculate positions and dimensions
//           final double topReducedPosition = -(baseCropViewHeight -
//               _kReducedCropViewHeight +
//               kToolbarHeight);
              
//           position = position.clamp(topReducedPosition, _kExtendedCropViewPosition);
          
//           final double cropViewVisibleHeight = (topWidgetHeight +
//                   position -
//                   topPadding -
//                   kToolbarHeight -
//                   _kPathSelectorRowHeight)
//               .clamp(_kReducedCropViewHeight, topWidgetHeight);
              
//           final double opacity = ((position / -topReducedPosition) + 1).clamp(0.4, 1.0);
          
//           final Duration animationDuration = position == topReducedPosition ||
//                   position == _kExtendedCropViewPosition
//               ? const Duration(milliseconds: 250)
//               : Duration.zero;

//           double gridHeight = mediaQuery.size.height -
//               kToolbarHeight -
//               _kReducedCropViewHeight;
              
//           // Adjust grid height when no assets
//           if (!provider.hasAssetsToDisplay) {
//             gridHeight -= baseCropViewHeight - -_cropViewPosition.value;
//           }
          
//           final double topPaddingValue = topWidgetHeight + position;
          
//           // Handle scroll target if needed
//           if (gridScrollController.hasClients && _scrollTargetOffset != null) {
//             gridScrollController.jumpTo(_scrollTargetOffset!);
//             _scrollTargetOffset = null;
//           }

//           return Stack(
//             children: [
//               // Grid view with optimized rebuilds
//               AnimatedPadding(
//                 padding: EdgeInsets.only(top: topPaddingValue),
//                 duration: animationDuration,
//                 child: SizedBox(
//                   height: gridHeight,
//                   width: screenWidth,
//                   child: NotificationListener<ScrollNotification>(
//                     onNotification: (notification) => _handleScroll(
//                       context,
//                       notification,
//                       position,
//                       topReducedPosition,
//                     ),
//                     child: _buildGrid(context),
//                   ),
//                 ),
//               ),
              
//               // App bar and crop view with optimized animations
//               AnimatedPositioned(
//                 top: position,
//                 duration: animationDuration,
//                 child: SizedBox(
//                   width: screenWidth,
//                   height: topWidgetHeight,
//                   child: AssetPickerAppBarWrapper(
//                     appBar: CupertinoNavigationBar(
//                       padding: const EdgeInsetsDirectional.fromSTEB(0, 0, 8, 0),
//                       leading: const CupertinoNavigationBarBackButton(
//                         color: CupertinoColors.activeBlue,
//                         previousPageTitle: 'Продукты',
//                       ),
//                       transitionBetweenRoutes: false,
//                       middle: title != null
//                           ? Text(
//                               title!,
//                               style: theme.appBarTheme.titleTextStyle,
//                             )
//                           : null,
//                       trailing: confirmButton(context),
//                     ),
//                     body: DecoratedBox(
//                       decoration: BoxDecoration(
//                         color: pickerTheme?.canvasColor,
//                       ),
//                       child: Column(
//                         children: [
//                           Listener(
//                             onPointerDown: (_) {
//                               _expandCropView();
//                               // Stop scroll event
//                               if (gridScrollController.hasClients) {
//                                 gridScrollController.jumpTo(gridScrollController.offset);
//                               }
//                             },
//                             child: CropViewer(
//                               key: _cropViewerKey,
//                               controller: _cropController,
//                               textDelegate: textDelegate,
//                               provider: provider,
//                               opacity: opacity,
//                               height: baseCropViewHeight,
//                               loaderWidget: Align(
//                                 alignment: Alignment.bottomCenter,
//                                 child: SizedBox(
//                                   height: cropViewVisibleHeight,
//                                   child: Center(
//                                     child: _buildLoader(context, 16),
//                                   ),
//                                 ),
//                               ),
//                               theme: pickerTheme,
//                             ),
//                           ),
//                           _buildActions(context),
//                         ],
//                       ),
//                     ),
//                   ),
//                 ),
//               ),
              
//               // Path and album selectors
//               pathEntityListBackdrop(context),
//               _buildListAlbums(context),
//             ],
//           );
//         },
//       ),
//     );
//   }

//   @override
//   Widget appleOSLayout(BuildContext context) => androidLayout(context);

//   // Optimized album list
//   Widget _buildListAlbums(BuildContext context) {
//     return Consumer<DefaultAssetPickerProvider>(
//       builder: (BuildContext context, provider, __) {
//         if (isAppleOS(context)) return pathEntityListWidget(context);

//         // Optimized position on Android
//         return ValueListenableBuilder<bool>(
//           valueListenable: isSwitchingPath,
//           builder: (_, bool isSwitchingPath, Widget? child) => Transform.translate(
//             offset: isSwitchingPath
//                 ? Offset(0, kToolbarHeight + MediaQuery.of(context).padding.top)
//                 : Offset.zero,
//             child: Stack(
//               children: [pathEntityListWidget(context)],
//             ),
//           ),
//         );
//       },
//     );
//   }

//   // Optimized path entity list
//   @override
//   Widget pathEntityListWidget(BuildContext context) {
//     appBarPreferredSize ??= appBar(context).preferredSize;
//     final mediaQuery = MediaQuery.of(context);
//     final bool isAppleOSFlag = isAppleOS(context);
    
//     return Positioned.fill(
//       top: isAppleOSFlag
//           ? mediaQuery.padding.top + kMinInteractiveDimensionCupertino
//           : 0,
//       bottom: null,
//       child: ValueListenableBuilder<bool>(
//         valueListenable: isSwitchingPath,
//         builder: (_, bool isSwitchingPath, Widget? child) => Semantics(
//           hidden: isSwitchingPath ? null : true,
//           child: AnimatedAlign(
//             duration: switchingPathDuration,
//             curve: switchingPathCurve,
//             alignment: Alignment.bottomCenter,
//             heightFactor: isSwitchingPath ? 1 : 0,
//             child: AnimatedOpacity(
//               duration: switchingPathDuration,
//               curve: switchingPathCurve,
//               opacity: !isAppleOSFlag || isSwitchingPath ? 1 : 0,
//               child: ClipRRect(
//                 borderRadius: const BorderRadius.vertical(
//                   bottom: Radius.circular(10),
//                 ),
//                 child: Container(
//                   constraints: BoxConstraints(
//                     maxHeight: mediaQuery.size.height * (isAppleOSFlag ? 0.6 : 0.8),
//                   ),
//                   color: theme.colorScheme.background,
//                   child: child,
//                 ),
//               ),
//             ),
//           ),
//         ),
//         child: Column(
//           mainAxisSize: MainAxisSize.min,
//           children: <Widget>[
//             // Permission indicator
//             ValueListenableBuilder<PermissionState>(
//               valueListenable: permissionNotifier,
//               builder: (_, PermissionState ps, Widget? child) => Semantics(
//                 label: '${semanticsTextDelegate.viewingLimitedAssetsTip}, '
//                     '${semanticsTextDelegate.changeAccessibleLimitedAssets}',
//                 button: true,
//                 onTap: PhotoManager.presentLimited,
//                 hidden: !isPermissionLimited,
//                 focusable: isPermissionLimited,
//                 excludeSemantics: true,
//                 child: isPermissionLimited ? child : const SizedBox.shrink(),
//               ),
//               child: Padding(
//                 padding: const EdgeInsets.symmetric(
//                   horizontal: 20,
//                   vertical: 12,
//                 ),
//                 child: Text.rich(
//                   TextSpan(
//                     children: <TextSpan>[
//                       TextSpan(
//                         text: textDelegate.viewingLimitedAssetsTip,
//                       ),
//                       TextSpan(
//                         text: ' ${textDelegate.changeAccessibleLimitedAssets}',
//                         style: TextStyle(color: interactiveTextColor(context)),
//                         recognizer: TapGestureRecognizer()
//                           ..onTap = PhotoManager.presentLimited,
//                       ),
//                     ],
//                   ),
//                   style: context.textTheme.bodySmall?.copyWith(fontSize: 14),
//                 ),
//               ),
//             ),
            
//             // Path list with optimized rebuilds
//             Flexible(
//               child: Selector<DefaultAssetPickerProvider, List<PathWrapper<AssetPathEntity>>>(
//                 selector: (_, DefaultAssetPickerProvider p) => p.paths,
//                 builder: (_, List<PathWrapper<AssetPathEntity>> paths, __) {
//                   // Filter only once
//                   final List<PathWrapper<AssetPathEntity>> filtered = paths
//                       .where((p) => p.assetCount != 0)
//                       .toList();
                      
//                   return ListView.separated(
//                     padding: const EdgeInsetsDirectional.only(top: 1),
//                     shrinkWrap: true,
//                     itemCount: filtered.length,
//                     itemBuilder: (c, i) => pathEntityWidget(
//                       context: c,
//                       list: filtered,
//                       index: i,
//                     ),
//                     separatorBuilder: (_, __) => Container(
//                       margin: const EdgeInsetsDirectional.only(start: 60),
//                       height: 1,
//                       color: Colors.grey[400],
//                     ),
//                   );
//                 },
//               ),
//             ),
//           ],
//         ),
//       ),
//     );
//   }

//   // Optimized path entity widget
//   @override
//   Widget pathEntityWidget({
//     required BuildContext context,
//     required List<PathWrapper<AssetPathEntity>> list,
//     required int index,
//   }) {
//     final PathWrapper<AssetPathEntity> wrapper = list[index];
//     final AssetPathEntity pathEntity = wrapper.path;
//     final Uint8List? data = wrapper.thumbnailData;
//     final bool isPermissionLimitedFlag = isPermissionLimited;
//     final bool isAppleOSFlag = isAppleOS(context);

//     // Thumbnail builder function
//     Widget thumbnailBuilder() {
//       if (data != null) {
//         return Image.memory(data, fit: BoxFit.cover);
//       }
//       if (pathEntity.type.containsAudio()) {
//         return ColoredBox(
//           color: theme.colorScheme.primary.withOpacity(0.12),
//           child: const Center(child: Icon(Icons.audiotrack)),
//         );
//       }
//       return ColoredBox(color: theme.colorScheme.primary.withOpacity(0.12));
//     }

//     // Get path name
//     final String pathName = pathNameBuilder?.call(pathEntity) ?? pathEntity.name;
//     final String name = isPermissionLimitedFlag && pathEntity.isAll
//         ? textDelegate.accessiblePathName
//         : pathName;
//     final String semanticsName = isPermissionLimitedFlag && pathEntity.isAll
//         ? semanticsTextDelegate.accessiblePathName
//         : pathName;
//     final String? semanticsCount = wrapper.assetCount?.toString();
    
//     // Build semantics label
//     final StringBuffer labelBuffer = StringBuffer(
//       '$semanticsName, ${semanticsTextDelegate.sUnitAssetCountLabel}',
//     );
//     if (semanticsCount != null) {
//       labelBuffer.write(': $semanticsCount');
//     }
    
//     return Selector<DefaultAssetPickerProvider, PathWrapper<AssetPathEntity>?>(
//       selector: (_, DefaultAssetPickerProvider p) => p.currentPath,
//       builder: (_, PathWrapper<AssetPathEntity>? currentWrapper, __) {
//         final bool isSelected = currentWrapper?.path == pathEntity;
//         return Semantics(
//           label: labelBuffer.toString(),
//           selected: isSelected,
//           onTapHint: semanticsTextDelegate.sActionSwitchPathLabel,
//           button: false,
//           child: Material(
//             color: Colors.white,
//             child: InkWell(
//               splashFactory: InkSplash.splashFactory,
//               onTap: () {
//                 Feedback.forTap(context);
//                 context.read<DefaultAssetPickerProvider>().switchPath(wrapper);
//                 isSwitchingPath.value = false;
//                 gridScrollController.jumpTo(0);
//               },
//               child: SizedBox(
//                 height: isAppleOSFlag ? 64 : 52,
//                 child: Row(
//                   children: <Widget>[
//                     RepaintBoundary(
//                       child: AspectRatio(aspectRatio: 1, child: thumbnailBuilder()),
//                     ),
//                     Expanded(
//                       child: Padding(
//                         padding: const EdgeInsetsDirectional.only(
//                           start: 15,
//                           end: 20,
//                         ),
//                         child: ExcludeSemantics(
//                           child: ScaleText.rich(
//                             [
//                               TextSpan(
//                                 text: name,
//                                 style: const TextStyle(color: Colors.black),
//                               ),
//                               if (semanticsCount != null)
//                                 TextSpan(
//                                   text: ' ($semanticsCount)',
//                                   style: const TextStyle(color: Colors.black),
//                                 ),
//                             ],
//                             style: const TextStyle(fontSize: 17),
//                             maxLines: 1,
//                             overflow: TextOverflow.ellipsis,
//                           ),
//                         ),
//                       ),
//                     ),
//                     if (isSelected)
//                       AspectRatio(
//                         aspectRatio: 1,
//                         child: Icon(
//                           CupertinoIcons.check_mark_circled,
//                           color: themeColor,
//                           size: 26,
//                         ),
//                       ),
//                   ],
//                 ),
//               ),
//             ),
//           ),
//         );
//       },
//     );
//   }

//   // Grid builder with optimized rebuilds
//   Widget _buildGrid(BuildContext context) {
//     return Consumer<DefaultAssetPickerProvider>(
//       builder: (BuildContext context, DefaultAssetPickerProvider p, __) {
//         final bool shouldDisplayAssets = p.hasAssetsToDisplay || shouldBuildSpecialItem;
//         _initializePreviewAsset(p, shouldDisplayAssets);

//         return AnimatedSwitcher(
//           duration: const Duration(milliseconds: 300),
//           child: shouldDisplayAssets
//               ? MediaQuery(
//                   data: MediaQuery.of(context).copyWith(
//                     padding: const EdgeInsets.only(top: -kToolbarHeight),
//                   ),
//                   child: RepaintBoundary(child: assetsGridBuilder(context)),
//                 )
//               : loadingIndicator(context),
//         );
//       },
//     );
//   }

//   /// To show selected assets indicator and preview asset overlay
//   @override
//   Widget selectIndicator(BuildContext context, int index, AssetEntity asset) {
//     final selectedAssets = provider.selectedAssets;
//     final Duration duration = switchingPathDuration * 0.75;

//     final int indexSelected = selectedAssets.indexOf(asset);
//     final bool isSelected = indexSelected != -1;

//     final Widget innerSelector = AnimatedContainer(
//       duration: duration,
//       width: _kIndicatorSize,
//       height: _kIndicatorSize,
//       padding: const EdgeInsets.all(2),
//       decoration: BoxDecoration(
//         boxShadow: [
//           BoxShadow(color: Colors.black26, blurRadius: 4, spreadRadius: 1)
//         ],
//         border: isSelected
//             ? null
//             : Border.all(color: theme.unselectedWidgetColor, width: 1.0),
//         color: isSelected
//             ? themeColor
//             : theme.unselectedWidgetColor.withOpacity(.2),
//         shape: BoxShape.circle,
//       ),
//       child: FittedBox(
//         child: AnimatedSwitcher(
//           duration: duration,
//           reverseDuration: duration,
//           child: isSelected
//               ? Text((indexSelected + 1).toString())
//               : const SizedBox.shrink(),
//         ),
//       ),
//     );

//     return ValueListenableBuilder<AssetEntity?>(
//       valueListenable: _cropController.previewAsset,
//       builder: (context, previewAsset, child) {
//         final bool isPreview = asset == _cropController.previewAsset.value;

//         return Positioned.fill(
//           child: GestureDetector(
//             onTap: isPreviewEnabled
//                 ? () => selectAsset(context, asset, index, isSelected)
//                 : null,
//             behavior: HitTestBehavior.opaque,
//             child: Padding(
//               padding: const EdgeInsets.all(4),
//               child: Align(
//                 alignment: AlignmentDirectional.topEnd,
//                 child: innerSelector,
//               ),
//             ),
//           ),
//         );
//       },
//     );
//   }

//   @override
//   Widget selectedBackdrop(BuildContext context, int index, AssetEntity asset) {
//     final double indicatorSize =
//         MediaQuery.sizeOf(context).width / gridCount / 3;
//     return Positioned.fill(
//       child: GestureDetector(
//         onTap: isPreviewEnabled
//             ? () {
//                 viewAsset(context, index, asset);
//               }
//             : null,
//         child: Consumer<DefaultAssetPickerProvider>(
//           builder: (_, DefaultAssetPickerProvider p, __) {
//             final int index = p.selectedAssets.indexOf(asset);
//             final bool selected = index != -1;
//             return AnimatedContainer(
//               duration: switchingPathDuration,
//               padding: EdgeInsets.all(indicatorSize * .35),
//               color: selected ? Colors.white.withValues(alpha: 0.5) : null,
//             );
//           },
//         ),
//       ),
//     );
//   }

//   /// Disable item banned indicator in single mode (#26) so that
//   /// the new selected asset replace the old one
//   @override
//   Widget itemBannedIndicator(BuildContext context, AssetEntity asset) =>
//       isSingleAssetMode
//           ? const SizedBox.shrink()
//           : super.itemBannedIndicator(context, asset);
// }