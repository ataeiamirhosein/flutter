// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'basic.dart';
import 'binding.dart';
import 'framework.dart';
import 'navigator.dart';

/// A piece of routing information.
///
/// The route information consists of a location string of the application and
/// a state object that configures the application in that location.
///
/// This information flows two ways, from the [RouteInformationProvider] to the
/// [Router] or from the [Router] to [RouteInformationProvider].
///
/// In the former case, the [RouteInformationProvider] notifies the [Router]
/// widget when a new [RouteInformation] is available. The [Router] widget takes
/// these information and navigates accordingly.
///
/// The latter case should only happen in a web application where the [Router]
/// reports route changes back to web engine.
class RouteInformation {
  /// Creates a route information object.
  ///
  /// The arguments may be null.
  const RouteInformation({this.location, this.state});

  /// The location of the application.
  ///
  /// The string is usually in the format of multiple string identifiers with
  /// slashes in between. ex: `/`, `/path`, `/path/to/the/app`.
  ///
  /// It is equivalent to the URL in a web application.
  final String? location;

  /// The state of the application in the [location].
  ///
  /// The app can have different states even in the same location. For example,
  /// the text inside a [TextField] or the scroll position in a [ScrollView].
  /// These widget states can be stored in the [state].
  ///
  /// Currently, this information is only used by Flutter on the web:
  /// the data is stored in the browser history entry when the
  /// [Router] reports this route information back to the web engine
  /// through the [PlatformRouteInformationProvider]. The information
  /// is then passed back, along with the [location], when the user
  /// clicks the back or forward buttons.
  ///
  /// The state must be serializable.
  final Object? state;
}

/// The dispatcher for opening and closing pages of an application.
///
/// This widget listens for routing information from the operating system (e.g.
/// an initial route provided on app startup, a new route obtained when an
/// intent is received, or a notification that the user hit the system back
/// button), parses route information into data of type `T`, and then converts
/// that data into [Page] objects that it passes to a [Navigator].
///
/// Each part of this process can be overridden and configured as desired.
///
/// The [routeInformationProvider] can be overridden to change how the name of
/// the route is obtained. The [RouteInformationProvider.value] is used as the
/// initial route when the [Router] is first created. Subsequent notifications
/// from the [RouteInformationProvider] to its listeners are treated as
/// notifications that the route information has changed.
///
/// The [backButtonDispatcher] can be overridden to change how back button
/// notifications are received. This must be a [BackButtonDispatcher], which is
/// an object where callbacks can be registered, and which can be chained so
/// that back button presses are delegated to subsidiary routers. The callbacks
/// are invoked to indicate that the user is trying to close the current route
/// (by pressing the system back button); the [Router] ensures that when this
/// callback is invoked, the message is passed to the [routerDelegate] and its
/// result is provided back to the [backButtonDispatcher]. Some platforms don't
/// have back buttons (e.g. iOS and desktop platforms); on those platforms this
/// notification is never sent. Typically, the [backButtonDispatcher] for the
/// root router is an instance of [RootBackButtonDispatcher], which uses a
/// [WidgetsBindingObserver] to listen to the `popRoute` notifications from
/// [SystemChannels.navigation]. Nested [Router]s typically use a
/// [ChildBackButtonDispatcher], which must be provided the
/// [BackButtonDispatcher] of its ancestor [Router] (available via [Router.of]).
///
/// The [routeInformationParser] can be overridden to change how names obtained
/// from the [routeInformationProvider] are interpreted. It must implement the
/// [RouteInformationParser] interface, specialized with the same type as the
/// [Router] itself. This type, `T`, represents the data type that the
/// [routeInformationParser] will generate.
///
/// The [routerDelegate] can be overridden to change how the output of the
/// [routeInformationParser] is interpreted. It must implement the
/// [RouterDelegate] interface, also specialized with `T`; it takes as input
/// the data (of type `T`) from the [routeInformationParser], and is responsible
/// for providing a navigating widget to insert into the widget tree. The
/// [RouterDelegate] interface is also [Listenable]; notifications are taken
/// to mean that the [Router] needs to rebuild.
///
/// ## Concerns regarding asynchrony
///
/// Some of the APIs (notably those involving [RouteInformationParser] and
/// [RouterDelegate]) are asynchronous.
///
/// When developing objects implementing these APIs, if the work can be done
/// entirely synchronously, then consider using [SynchronousFuture] for the
/// future returned from the relevant methods. This will allow the [Router] to
/// proceed in a completely synchronous way, which removes a number of
/// complications.
///
/// Using asynchronous computation is entirely reasonable, however, and the API
/// is designed to support it. For example, maybe a set of images need to be
/// loaded before a route can be shown; waiting for those images to be loaded
/// before [RouterDelegate.setNewRoutePath] returns is a reasonable approach to
/// handle this case.
///
/// If an asynchronous operation is ongoing when a new one is to be started, the
/// precise behavior will depend on the exact circumstances, as follows:
///
/// If the active operation is a [routeInformationParser] parsing a new route information:
/// that operation's result, if it ever completes, will be discarded.
///
/// If the active operation is a [routerDelegate] handling a pop request:
/// the previous pop is immediately completed with "false", claiming that the
/// previous pop was not handled (this may cause the application to close).
///
/// If the active operation is a [routerDelegate] handling an initial route
/// or a pushed route, the result depends on the new operation. If the new
/// operation is a pop request, then the original operation's result, if it ever
/// completes, will be discarded. If the new operation is a push request,
/// however, the [routeInformationParser] will be requested to start the parsing, and
/// only if that finishes before the original [routerDelegate] request
/// completes will that original request's result be discarded.
///
/// If the identity of the [Router] widget's delegates change while an
/// asynchronous operation is in progress, to keep matters simple, all active
/// asynchronous operations will have their results discarded. It is generally
/// considered unusual for these delegates to change during the lifetime of the
/// [Router].
///
/// If the [Router] itself is disposed while an asynchronous operation is in
/// progress, all active asynchronous operations will have their results
/// discarded also.
///
/// No explicit signals are provided to the [routeInformationParser] or
/// [routerDelegate] to indicate when any of the above happens, so it is
/// strongly recommended that [RouteInformationParser] and [RouterDelegate]
/// implementations not perform extensive computation.
///
/// ## Application architectural design
///
/// An application can have zero, one, or many [Router] widgets, depending on
/// its needs.
///
/// An application might have no [Router] widgets if it has only one "screen",
/// or if the facilities provided by [Navigator] are sufficient. This is common
/// for desktop applications, where subsidiary "screens" are represented using
/// different windows rather than changing the active interface.
///
/// A particularly elaborate application might have multiple [Router] widgets,
/// in a tree configuration, with the first handling the entire route parsing
/// and making the result available for routers in the subtree. The routers in
/// the subtree do not participate in route information parsing but merely take the
/// result from the first router to build their sub routes.
///
/// Most applications only need a single [Router].
///
/// ## URL updates for web applications
///
/// In the web platform, keeping the URL in the browser's location bar up to
/// date with the application state ensures that the browser constructs its
/// history entry correctly, allowing its back and forward buttons to function
/// as the user expects.
///
/// If an app state change leads to the [Router] rebuilding, the [Router] will
/// retrieve the new route information from the [routerDelegate]'s
/// [RouterDelegate.currentConfiguration] method and the
/// [routeInformationParser]'s [RouteInformationParser.restoreRouteInformation]
/// method. If the location in the new route information is different from the
/// current location, the router sends the new route information to the
/// [routeInformationProvider]'s
/// [RouteInformationProvider.routerReportsNewRouteInformation] method. That
/// method as implemented in [PlatformRouteInformationProvider] uses
/// [SystemNavigator.routeInformationUpdated] to notify the engine, and through
/// that the browser, of the new URL.
///
/// One can force the [Router] to report new route information to the
/// [routeInformationProvider] (and thus the browser) even if the
/// [RouteInformation.location] has not changed by calling the [Router.navigate]
/// method with a callback that performs the state change. This allows one to
/// support the browser's back and forward buttons without changing the URL. For
/// example, the scroll position of a scroll view may be saved in the
/// [RouteInformation.state]. Using [Router.navigate] to update the scroll
/// position causes the browser to create a new history entry with the
/// [RouteInformation.state] that stores this new scroll position. When the user
/// clicks the back button, the app will go back to the previous scroll position
/// without changing the URL in the location bar.
///
/// One can also force the [Router] to ignore application state changes by
/// making those changes during a callback passed to [Router.neglect]. The
/// [Router] will not report any route information even if it detects location
/// change as a result of running the callback.
///
/// To opt out of URL updates entirely, pass null for [routeInformationProvider]
/// and [routeInformationParser]. This is not recommended in general, but may be
/// appropriate in the following cases:
///
/// * The application does not target the web platform.
///
/// * There are multiple router widgets in the application. Only one [Router]
///   widget should update the URL (typically the top-most one created by the
///   [WidgetsApp.router], [MaterialApp.router], or [CupertinoApp.router]).
///
/// * The application does not need to implement in-app navigation using the
///   browser's back and forward buttons.
///
/// In other cases, it is strongly recommended to implement the
/// [RouterDelegate.currentConfiguration] and
/// [RouteInformationParser.restoreRouteInformation] APIs to provide an optimal
/// user experience when running on the web platform.
class Router<T> extends StatefulWidget {
  /// Creates a router.
  ///
  /// The [routeInformationProvider] and [routeInformationParser] can be null if this
  /// router does not depend on route information. A common example is a sub router
  /// that builds its content completely based on the app state.
  ///
  /// If the [routeInformationProvider] is not null, the [routeInformationParser] must
  /// also not be null.
  ///
  /// The [routerDelegate] must not be null.
  const Router({
    Key? key,
    this.routeInformationProvider,
    this.routeInformationParser,
    required this.routerDelegate,
    this.backButtonDispatcher,
  })  : assert(
          (routeInformationProvider == null) == (routeInformationParser == null),
          'Both routeInformationProvider and routeInformationParser must be provided '
          'if this router parses route information. Otherwise, they should both '
          'be null.',
        ),
        assert(routerDelegate != null),
        super(key: key);

  /// The route information provider for the router.
  ///
  /// The value at the time of first build will be used as the initial route.
  /// The [Router] listens to this provider and rebuilds with new names when
  /// it notifies.
  ///
  /// This can be null if this router does not rely on the route information
  /// to build its content. In such case, the [routeInformationParser] can also be
  /// null.
  final RouteInformationProvider? routeInformationProvider;

  /// The route information parser for the router.
  ///
  /// When the [Router] gets a new route information from the [routeInformationProvider],
  /// the [Router] uses this delegate to parse the route information and produce a
  /// configuration. The configuration will be used by [routerDelegate] and
  /// eventually rebuilds the [Router] widget.
  ///
  /// Since this delegate is the primary consumer of the [routeInformationProvider],
  /// it must not be null if [routeInformationProvider] is not null.
  final RouteInformationParser<T>? routeInformationParser;

  /// The router delegate for the router.
  ///
  /// This delegate consumes the configuration from [routeInformationParser] and
  /// builds a navigating widget for the [Router].
  ///
  /// It is also the primary respondent for the [backButtonDispatcher]. The
  /// [Router] relies on [RouterDelegate.popRoute] to handle the back
  /// button.
  ///
  /// If the [RouterDelegate.currentConfiguration] returns a non-null object,
  /// this [Router] will opt for URL updates.
  final RouterDelegate<T> routerDelegate;

  /// The back button dispatcher for the router.
  ///
  /// The two common alternatives are the [RootBackButtonDispatcher] for root
  /// router, or the [ChildBackButtonDispatcher] for other routers.
  final BackButtonDispatcher? backButtonDispatcher;

  /// Retrieves the immediate [Router] ancestor from the given context.
  ///
  /// This method provides access to the delegates in the [Router]. For example,
  /// this can be used to access the [backButtonDispatcher] of the parent router
  /// when creating a [ChildBackButtonDispatcher] for a nested [Router].
  ///
  /// If no [Router] ancestor exists for the given context, this will assert in
  /// debug mode, and throw an exception in release mode.
  ///
  /// See also:
  ///
  ///  * [maybeOf], which is a similar function, but it will return null instead
  ///    of throwing an exception if no [Router] ancestor exists.
  static Router<dynamic> of(BuildContext context) {
    final _RouterScope? scope = context.dependOnInheritedWidgetOfExactType<_RouterScope>();
    assert(() {
      if (scope == null) {
        throw FlutterError(
          'Router operation requested with a context that does not include a Router.\n'
          'The context used to retrieve the Router must be that of a widget that '
          'is a descendant of a Router widget.',
        );
      }
      return true;
    }());
    return scope!.routerState.widget;
  }

  /// Retrieves the immediate [Router] ancestor from the given context.
  ///
  /// This method provides access to the delegates in the [Router]. For example,
  /// this can be used to access the [backButtonDispatcher] of the parent router
  /// when creating a [ChildBackButtonDispatcher] for a nested [Router].
  ///
  /// If no `Router` ancestor exists for the given context, this will return
  /// null.
  ///
  /// See also:
  ///
  ///  * [of], a similar method that returns a non-nullable value, and will
  ///    throw if no [Router] ancestor exists.
  static Router<dynamic>? maybeOf(BuildContext context) {
    final _RouterScope? scope = context.dependOnInheritedWidgetOfExactType<_RouterScope>();
    return scope?.routerState.widget;
  }

  /// Forces the [Router] to run the [callback] and reports the route
  /// information back to the engine.
  ///
  /// The web application relies on the [Router] to report new route information
  /// in order to create browser history entry. The [Router] will only report
  /// them if it detects the [RouteInformation.location] changes. Use this
  /// method if you want the [Router] to report the route information even if
  /// the location does not change. This can be useful when you want to
  /// support the browser backward and forward button without changing the URL.
  ///
  /// For example, you can store certain state such as the scroll position into
  /// the [RouteInformation.state]. If you use this method to update the
  /// scroll position multiple times with the same URL, the browser will create
  /// a stack of new history entries with the same URL but different
  /// [RouteInformation.state]s that store the new scroll positions. If the user
  /// click the backward button in the browser, the browser will restore the
  /// scroll positions saved in history entries without changing the URL.
  ///
  /// See also:
  ///
  ///  * [Router]: see the "URL updates for web applications" section for more
  ///    information about route information reporting.
  ///  * [neglect]: which forces the [Router] to not report the route
  ///    information even if location does change.
  static void navigate(BuildContext context, VoidCallback callback) {
    final _RouterScope scope = context
      .getElementForInheritedWidgetOfExactType<_RouterScope>()!
      .widget as _RouterScope;
    scope.routerState._setStateWithExplicitReportStatus(_IntentionToReportRouteInformation.must, callback);
  }

  /// Forces the [Router] to to run the [callback] without reporting the route
  /// information back to the engine.
  ///
  /// Use this method if you don't want the [Router] to report the new route
  /// information even if it detects changes as a result of running the
  /// [callback].
  ///
  /// The web application relies on the [Router] to report new route information
  /// in order to create browser history entry. The [Router] will report them
  /// automatically if it detects the [RouteInformation.location] changes. You
  /// can use this method if you want to navigate to a new route without
  /// creating the browser history entry.
  ///
  /// See also:
  ///
  ///  * [Router]: see the "URL updates for web applications" section for more
  ///    information about route information reporting.
  ///  * [navigate]: which forces the [Router] to report the route information
  ///    even if location does not change.
  static void neglect(BuildContext context, VoidCallback callback) {
    final _RouterScope scope = context
      .getElementForInheritedWidgetOfExactType<_RouterScope>()!
      .widget as _RouterScope;
    scope.routerState._setStateWithExplicitReportStatus(_IntentionToReportRouteInformation.ignore, callback);
  }

  @override
  State<Router<T>> createState() => _RouterState<T>();
}

typedef _AsyncPassthrough<Q> = Future<Q> Function(Q);

// Whether to report the route information in this build cycle.
enum _IntentionToReportRouteInformation {
  // We haven't receive any signal on whether to report.
  none,
  // Report if route information changes.
  maybe,
  // Report regardless of route information changes.
  must,
  // Don't report regardless of route information changes.
  ignore,
}

class _RouterState<T> extends State<Router<T>> {
  Object? _currentRouteInformationParserTransaction;
  Object? _currentRouterDelegateTransaction;
  late _IntentionToReportRouteInformation _currentIntentionToReport;

  @override
  void initState() {
    super.initState();
    widget.routeInformationProvider?.addListener(_handleRouteInformationProviderNotification);
    widget.backButtonDispatcher?.addCallback(_handleBackButtonDispatcherNotification);
    widget.routerDelegate.addListener(_handleRouterDelegateNotification);
    _currentIntentionToReport = _IntentionToReportRouteInformation.none;
    if (widget.routeInformationProvider != null) {
      _processInitialRoute();
    }
  }

  bool _routeInformationReportingTaskScheduled = false;

  String? _lastSeenLocation;

  void _scheduleRouteInformationReportingTask() {
    if (_routeInformationReportingTaskScheduled)
      return;
    assert(_currentIntentionToReport != _IntentionToReportRouteInformation.none);
    _routeInformationReportingTaskScheduled = true;
    SchedulerBinding.instance!.addPostFrameCallback(_reportRouteInformation);
  }

  void _reportRouteInformation(Duration timestamp) {
    assert(_routeInformationReportingTaskScheduled);
    _routeInformationReportingTaskScheduled = false;

    switch (_currentIntentionToReport) {
      case _IntentionToReportRouteInformation.none:
        assert(false);
        return;

      case _IntentionToReportRouteInformation.ignore:
        // In the ignore case, we still want to update the _lastSeenLocation.
        final RouteInformation? routeInformation = _retrieveNewRouteInformation();
        if (routeInformation != null) {
          _lastSeenLocation = routeInformation.location;
        }
        _currentIntentionToReport = _IntentionToReportRouteInformation.none;
        return;

      case _IntentionToReportRouteInformation.maybe:
        final RouteInformation? routeInformation = _retrieveNewRouteInformation();
        if (routeInformation != null) {
          if (_lastSeenLocation != routeInformation.location) {
            widget.routeInformationProvider!.routerReportsNewRouteInformation(routeInformation);
            _lastSeenLocation = routeInformation.location;
          }
        }
        _currentIntentionToReport = _IntentionToReportRouteInformation.none;
        return;

      case _IntentionToReportRouteInformation.must:
        final RouteInformation? routeInformation = _retrieveNewRouteInformation();
        if (routeInformation != null) {
          widget.routeInformationProvider!.routerReportsNewRouteInformation(routeInformation);
          _lastSeenLocation = routeInformation.location;
        }
        _currentIntentionToReport = _IntentionToReportRouteInformation.none;
        return;
    }
  }

  RouteInformation? _retrieveNewRouteInformation() {
    final T? configuration = widget.routerDelegate.currentConfiguration;
    if (configuration == null)
      return null;
    final RouteInformation? routeInformation = widget.routeInformationParser!.restoreRouteInformation(configuration);
    assert((){
      if (routeInformation == null) {
        FlutterError.reportError(
          const FlutterErrorDetails(
            exception:
              'Router.routeInformationParser returns a null RouteInformation. '
              'If you opt for route information reporting, the '
              'routeInformationParser must not report null for a given '
              'configuration.',
          ),
        );
      }
      return true;
    }());
    return routeInformation;
  }

  void _setStateWithExplicitReportStatus(
    _IntentionToReportRouteInformation status,
    VoidCallback fn,
  ) {
    assert(status != null);
    assert(status.index >= _IntentionToReportRouteInformation.must.index);
    assert(() {
      if (_currentIntentionToReport.index >= _IntentionToReportRouteInformation.must.index &&
          _currentIntentionToReport != status) {
        FlutterError.reportError(
          const FlutterErrorDetails(
            exception:
              'Both Router.navigate and Router.neglect have been called in this '
              'build cycle, and the Router cannot decide whether to report the '
              'route information. Please make sure only one of them is called '
              'within the same build cycle.',
          ),
        );
      }
      return true;
    }());
    _currentIntentionToReport = status;
    _scheduleRouteInformationReportingTask();
    fn();
  }

  void _maybeNeedToReportRouteInformation() {
    _currentIntentionToReport = _currentIntentionToReport != _IntentionToReportRouteInformation.none
      ? _currentIntentionToReport
      : _IntentionToReportRouteInformation.maybe;
    _scheduleRouteInformationReportingTask();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeNeedToReportRouteInformation();
  }

  @override
  void didUpdateWidget(Router<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.routeInformationProvider != oldWidget.routeInformationProvider ||
        widget.backButtonDispatcher != oldWidget.backButtonDispatcher ||
        widget.routeInformationParser != oldWidget.routeInformationParser ||
        widget.routerDelegate != oldWidget.routerDelegate) {
      _currentRouteInformationParserTransaction = Object();
      _currentRouterDelegateTransaction = Object();
    }
    if (widget.routeInformationProvider != oldWidget.routeInformationProvider) {
      oldWidget.routeInformationProvider?.removeListener(_handleRouteInformationProviderNotification);
      widget.routeInformationProvider?.addListener(_handleRouteInformationProviderNotification);
      if (oldWidget.routeInformationProvider?.value != widget.routeInformationProvider?.value) {
        _handleRouteInformationProviderNotification();
      }
    }
    if (widget.backButtonDispatcher != oldWidget.backButtonDispatcher) {
      oldWidget.backButtonDispatcher?.removeCallback(_handleBackButtonDispatcherNotification);
      widget.backButtonDispatcher?.addCallback(_handleBackButtonDispatcherNotification);
    }
    if (widget.routerDelegate != oldWidget.routerDelegate) {
      oldWidget.routerDelegate.removeListener(_handleRouterDelegateNotification);
      widget.routerDelegate.addListener(_handleRouterDelegateNotification);
      _maybeNeedToReportRouteInformation();
    }
  }

  @override
  void dispose() {
    widget.routeInformationProvider?.removeListener(_handleRouteInformationProviderNotification);
    widget.backButtonDispatcher?.removeCallback(_handleBackButtonDispatcherNotification);
    widget.routerDelegate.removeListener(_handleRouterDelegateNotification);
    _currentRouteInformationParserTransaction = null;
    _currentRouterDelegateTransaction = null;
    super.dispose();
  }

  void _processInitialRoute() {
    _currentRouteInformationParserTransaction = Object();
    _currentRouterDelegateTransaction = Object();
    _lastSeenLocation = widget.routeInformationProvider!.value!.location;
    widget.routeInformationParser!
      .parseRouteInformation(widget.routeInformationProvider!.value!)
      .then<T>(_verifyRouteInformationParserStillCurrent(_currentRouteInformationParserTransaction, widget))
      .then<void>(widget.routerDelegate.setInitialRoutePath)
      .then<void>(_verifyRouterDelegatePushStillCurrent(_currentRouterDelegateTransaction, widget))
      .then<void>(_rebuild);
  }

  void _handleRouteInformationProviderNotification() {
    _currentRouteInformationParserTransaction = Object();
    _currentRouterDelegateTransaction = Object();
    _lastSeenLocation = widget.routeInformationProvider!.value!.location;
    widget.routeInformationParser!
      .parseRouteInformation(widget.routeInformationProvider!.value!)
      .then<T>(_verifyRouteInformationParserStillCurrent(_currentRouteInformationParserTransaction, widget))
      .then<void>(widget.routerDelegate.setNewRoutePath)
      .then<void>(_verifyRouterDelegatePushStillCurrent(_currentRouterDelegateTransaction, widget))
      .then<void>(_rebuild);
  }

  Future<bool> _handleBackButtonDispatcherNotification() {
    _currentRouteInformationParserTransaction = Object();
    _currentRouterDelegateTransaction = Object();
    return widget.routerDelegate
      .popRoute()
      .then<bool>(_verifyRouterDelegatePopStillCurrent(_currentRouterDelegateTransaction, widget))
      .then<bool>((bool data) {
        _rebuild();
        _maybeNeedToReportRouteInformation();
        return SynchronousFuture<bool>(data);
      });
  }

  static final Future<dynamic> _never = Completer<dynamic>().future; // won't ever complete

  _AsyncPassthrough<T> _verifyRouteInformationParserStillCurrent(Object? transaction, Router<T> originalWidget) {
    return (T data) {
      if (transaction == _currentRouteInformationParserTransaction &&
          widget.routeInformationProvider == originalWidget.routeInformationProvider &&
          widget.backButtonDispatcher == originalWidget.backButtonDispatcher &&
          widget.routeInformationParser == originalWidget.routeInformationParser &&
          widget.routerDelegate == originalWidget.routerDelegate) {
        return SynchronousFuture<T>(data);
      }
      return _never as Future<T>;
    };
  }

  _AsyncPassthrough<void> _verifyRouterDelegatePushStillCurrent(Object? transaction, Router<T> originalWidget) {
    return (void data) {
      if (transaction == _currentRouterDelegateTransaction &&
          widget.routeInformationProvider == originalWidget.routeInformationProvider &&
          widget.backButtonDispatcher == originalWidget.backButtonDispatcher &&
          widget.routeInformationParser == originalWidget.routeInformationParser &&
          widget.routerDelegate == originalWidget.routerDelegate)
        return SynchronousFuture<void>(data);
      return _never;
    };
  }

  _AsyncPassthrough<bool> _verifyRouterDelegatePopStillCurrent(Object? transaction, Router<T> originalWidget) {
    return (bool data) {
      if (transaction == _currentRouterDelegateTransaction &&
          widget.routeInformationProvider == originalWidget.routeInformationProvider &&
          widget.backButtonDispatcher == originalWidget.backButtonDispatcher &&
          widget.routeInformationParser == originalWidget.routeInformationParser &&
          widget.routerDelegate == originalWidget.routerDelegate) {
        return SynchronousFuture<bool>(data);
      }
      // A rebuilt was trigger from a different source. Returns true to
      // prevent bubbling.
      return SynchronousFuture<bool>(true);
    };
  }

  Future<void> _rebuild([void value]) {
    setState(() {/* routerDelegate is ready to rebuild */});
    return SynchronousFuture<void>(value);
  }

  void _handleRouterDelegateNotification() {
    setState(() {/* routerDelegate wants to rebuild */});
    _maybeNeedToReportRouteInformation();
  }

  @override
  Widget build(BuildContext context) {
    return _RouterScope(
      routeInformationProvider: widget.routeInformationProvider,
      backButtonDispatcher: widget.backButtonDispatcher,
      routeInformationParser: widget.routeInformationParser,
      routerDelegate: widget.routerDelegate,
      routerState: this,
      child: Builder(
        // We use a Builder so that the build method below
        // will have a BuildContext that contains the _RouterScope.
        builder: widget.routerDelegate.build,
      ),
    );
  }
}

class _RouterScope extends InheritedWidget {
  const _RouterScope({
    Key? key,
    required this.routeInformationProvider,
    required this.backButtonDispatcher,
    required this.routeInformationParser,
    required this.routerDelegate,
    required this.routerState,
    required Widget child,
  })  : assert(routeInformationProvider == null || routeInformationParser != null),
        assert(routerDelegate != null),
        assert(routerState != null),
        super(key: key, child: child);

  final ValueListenable<RouteInformation?>? routeInformationProvider;
  final BackButtonDispatcher? backButtonDispatcher;
  final RouteInformationParser<dynamic>? routeInformationParser;
  final RouterDelegate<dynamic> routerDelegate;
  final _RouterState<dynamic> routerState;

  @override
  bool updateShouldNotify(_RouterScope oldWidget) {
    return routeInformationProvider != oldWidget.routeInformationProvider ||
           backButtonDispatcher != oldWidget.backButtonDispatcher ||
           routeInformationParser != oldWidget.routeInformationParser ||
           routerDelegate != oldWidget.routerDelegate ||
           routerState != oldWidget.routerState;
  }
}

/// A class that can be extended or mixed in that invokes a single callback,
/// which then returns a value.
///
/// While multiple callbacks can be registered, when a notification is
/// dispatched there must be only a single callback. The return values of
/// multiple callbacks are not aggregated.
///
/// `T` is the return value expected from the callback.
///
/// See also:
///
///  * [Listenable] and its subclasses, which provide a similar mechanism for
///    one-way signalling.
class _CallbackHookProvider<T> {
  final ObserverList<ValueGetter<T>> _callbacks = ObserverList<ValueGetter<T>>();

  /// Whether a callback is currently registered.
  @protected
  bool get hasCallbacks => _callbacks.isNotEmpty;

  /// Register the callback to be called when the object changes.
  ///
  /// If other callbacks have already been registered, they must be removed
  /// (with [removeCallback]) before the callback is next called.
  void addCallback(ValueGetter<T> callback) => _callbacks.add(callback);

  /// Remove a previously registered callback.
  ///
  /// If the given callback is not registered, the call is ignored.
  void removeCallback(ValueGetter<T> callback) => _callbacks.remove(callback);

  /// Calls the (single) registered callback and returns its result.
  ///
  /// If no callback is registered, or if the callback throws, returns
  /// `defaultValue`.
  ///
  /// Call this method whenever the callback is to be invoked. If there is more
  /// than one callback registered, this method will throw a [StateError].
  ///
  /// Exceptions thrown by callbacks will be caught and reported using
  /// [FlutterError.reportError].
  @protected
  T invokeCallback(T defaultValue) {
    if (_callbacks.isEmpty)
      return defaultValue;
    try {
      return _callbacks.single();
    } catch (exception, stack) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: exception,
        stack: stack,
        library: 'widget library',
        context: ErrorDescription('while invoking the callback for $runtimeType'),
        informationCollector: () sync* {
          yield DiagnosticsProperty<_CallbackHookProvider<T>>(
            'The $runtimeType that invoked the callback was:',
            this,
            style: DiagnosticsTreeStyle.errorProperty,
          );
        },
      ));
      return defaultValue;
    }
  }
}

/// Report to a [Router] when the user taps the back button on platforms that
/// support back buttons (such as Android).
///
/// When [Router] widgets are nested, consider using a
/// [ChildBackButtonDispatcher], passing it the parent [BackButtonDispatcher],
/// so that the back button requests get dispatched to the appropriate [Router].
/// To make this work properly, it's important that whenever a [Router] thinks
/// it should get the back button messages (e.g. after the user taps inside it),
/// it calls [takePriority] on its [BackButtonDispatcher] (or
/// [ChildBackButtonDispatcher]) instance.
///
/// The class takes a single callback, which must return a [Future<bool>]. The
/// callback's semantics match [WidgetsBindingObserver.didPopRoute]'s, namely,
/// the callback should return a future that completes to true if it can handle
/// the pop request, and a future that completes to false otherwise.
abstract class BackButtonDispatcher extends _CallbackHookProvider<Future<bool>> {
  late final LinkedHashSet<ChildBackButtonDispatcher> _children =
    <ChildBackButtonDispatcher>{} as LinkedHashSet<ChildBackButtonDispatcher>;

  @override
  bool get hasCallbacks => super.hasCallbacks || (_children.isNotEmpty);

  /// Handles a pop route request.
  ///
  /// This method prioritizes the children list in reverse order and calls
  /// [ChildBackButtonDispatcher.notifiedByParent] on them. If any of them
  /// handles the request (by returning a future with true), it exits this
  /// method by returning this future. Otherwise, it keeps moving on to the next
  /// child until a child handles the request. If none of the children handles
  /// the request, this back button dispatcher will then try to handle the request
  /// by itself. This back button dispatcher handles the request by notifying the
  /// router which in turn calls the [RouterDelegate.popRoute] and returns its
  /// result.
  ///
  /// To decide whether this back button dispatcher will handle the pop route
  /// request, you can override the [RouterDelegate.popRoute] of the router
  /// delegate you pass into the router with this back button dispatcher to
  /// return a future of true or false.
  @override
  Future<bool> invokeCallback(Future<bool> defaultValue) {
    if (_children.isNotEmpty) {
      final List<ChildBackButtonDispatcher> children = _children.toList();
      int childIndex = children.length - 1;

      Future<bool> notifyNextChild(bool result) {
        // If the previous child handles the callback, we return the result.
        if (result)
          return SynchronousFuture<bool>(result);
        // If the previous child did not handle the callback, we ask the next
        // child to handle the it.
        if (childIndex > 0) {
          childIndex -= 1;
          return children[childIndex]
            .notifiedByParent(defaultValue)
            .then<bool>(notifyNextChild);
        }
        // If none of the child handles the callback, the parent will then handle it.
        return super.invokeCallback(defaultValue);
      }

      return children[childIndex]
        .notifiedByParent(defaultValue)
        .then<bool>(notifyNextChild);
    }
    return super.invokeCallback(defaultValue);
  }

  /// Creates a [ChildBackButtonDispatcher] that is a direct descendant of this
  /// back button dispatcher.
  ///
  /// To participate in handling the pop route request, call the [takePriority]
  /// on the [ChildBackButtonDispatcher] created from this method.
  ///
  /// When the pop route request is handled by this back button dispatcher, it
  /// propagate the request to its direct descendants that have called the
  /// [takePriority] method. If there are multiple candidates, the latest one
  /// that called the [takePriority] wins the right to handle the request. If
  /// the latest one does not handle the request (by returning a future of
  /// false in [ChildBackButtonDispatcher.notifiedByParent]), the second latest
  /// one will then have the right to handle the request. This dispatcher
  /// continues finding the next candidate until there are no more candidates
  /// and finally handles the request itself.
  ChildBackButtonDispatcher createChildBackButtonDispatcher() {
    return ChildBackButtonDispatcher(this);
  }

  /// Make this [BackButtonDispatcher] take priority among its peers.
  ///
  /// This has no effect when a [BackButtonDispatcher] has no parents and no
  /// children. If a [BackButtonDispatcher] does have parents or children,
  /// however, it causes this object to be the one to dispatch the notification
  /// when the parent would normally notify its callback.
  ///
  /// The [BackButtonDispatcher] must have a listener registered before it can
  /// be told to take priority.
  void takePriority() => _children.clear();

  /// Mark the given child as taking priority over this object and the other
  /// children.
  ///
  /// This causes [invokeCallback] to defer to the given child instead of
  /// calling this object's callback.
  ///
  /// Children are stored in a list, so that if the current child is removed
  /// using [forget], a previous child will return to take its place. When
  /// [takePriority] is called, the list is cleared.
  ///
  /// Calling this again without first calling [forget] moves the child back to
  /// the head of the list.
  ///
  /// The [BackButtonDispatcher] must have a listener registered before it can
  /// be told to defer to a child.
  void deferTo(ChildBackButtonDispatcher child) {
    assert(hasCallbacks);
    _children.remove(child); // child may or may not be in the set already
    _children.add(child);
  }

  /// Causes the given child to be removed from the list of children to which
  /// this object might defer, as if [deferTo] had never been called for that
  /// child.
  ///
  /// This should only be called once per child, even if [deferTo] was called
  /// multiple times for that child.
  ///
  /// If no children are left in the list, this object will stop deferring to
  /// its children. (This is not the same as calling [takePriority], since, if
  /// this object itself is a [ChildBackButtonDispatcher], [takePriority] would
  /// additionally attempt to claim priority from its parent, whereas removing
  /// the last child does not.)
  void forget(ChildBackButtonDispatcher child) => _children.remove(child);
}

/// The default implementation of back button dispatcher for the root router.
///
/// This dispatcher listens to platform pop route notifications. When the
/// platform wants to pop the current route, this dispatcher calls the
/// [BackButtonDispatcher.invokeCallback] method to handle the request.
class RootBackButtonDispatcher extends BackButtonDispatcher with WidgetsBindingObserver {
  /// Create a root back button dispatcher.
  RootBackButtonDispatcher();

  @override
  void addCallback(ValueGetter<Future<bool>> callback) {
    if (!hasCallbacks)
      WidgetsBinding.instance!.addObserver(this);
    super.addCallback(callback);
  }

  @override
  void removeCallback(ValueGetter<Future<bool>> callback) {
    super.removeCallback(callback);
    if (!hasCallbacks)
      WidgetsBinding.instance!.removeObserver(this);
  }

  @override
  Future<bool> didPopRoute() => invokeCallback(Future<bool>.value(false));
}

/// A variant of [BackButtonDispatcher] which listens to notifications from a
/// parent back button dispatcher, and can take priority from its parent for the
/// handling of such notifications.
///
/// Useful when [Router]s are being nested within each other.
///
/// Use [Router.of] to obtain a reference to the nearest ancestor [Router], from
/// which the [Router.backButtonDispatcher] can be found, and then used as the
/// [parent] of the [ChildBackButtonDispatcher].
class ChildBackButtonDispatcher extends BackButtonDispatcher {
  /// Creates a back button dispatcher that acts as the child of another.
  ///
  /// The [parent] must not be null.
  ChildBackButtonDispatcher(this.parent) : assert(parent != null);

  /// The back button dispatcher that this object will attempt to take priority
  /// over when [takePriority] is called.
  ///
  /// The parent must have a listener registered before this child object can
  /// have its [takePriority] or [deferTo] methods used.
  final BackButtonDispatcher parent;

  /// The parent of this child back button dispatcher decide to let this
  /// child to handle the invoke the  callback request in
  /// [BackButtonDispatcher.invokeCallback].
  ///
  /// Return a boolean future with true if this child will handle the request;
  /// otherwise, return a boolean future with false.
  @protected
  Future<bool> notifiedByParent(Future<bool> defaultValue) {
    return invokeCallback(defaultValue);
  }

  @override
  void takePriority() {
    parent.deferTo(this);
    super.takePriority();
  }

  @override
  void deferTo(ChildBackButtonDispatcher child) {
    assert(hasCallbacks);
    parent.deferTo(this);
    super.deferTo(child);
  }

  @override
  void removeCallback(ValueGetter<Future<bool>> callback) {
    super.removeCallback(callback);
    if (!hasCallbacks)
      parent.forget(this);
  }
}

/// A convenience widget that registers a callback for when the back button is pressed.
///
/// In order to use this widget, there must be an ancestor [Router] widget in the tree
/// that has a [RootBackButtonDispatcher]. e.g. The [Router] widget created by the
/// [MaterialApp.router] has a built-in [RootBackButtonDispatcher] by default.
///
/// It only applies to platforms that accept back button clicks, such as Android.
///
/// It can be useful for scenarios, in which you create a different state in your
/// screen but don't want to use a new page for that.
class BackButtonListener extends StatefulWidget {
  /// Creates a BackButtonListener widget .
  ///
  /// The [child] and [onBackButtonPressed] arguments must not be null.
  const BackButtonListener({
    Key? key,
    required this.child,
    required this.onBackButtonPressed,
  }) : super(key: key);

  /// The widget below this widget in the tree.
  final Widget child;

  /// The callback function that will be called when the back button is pressed.
  ///
  /// It must return a boolean future with true if this child will handle the request;
  /// otherwise, return a boolean future with false.
  final ValueGetter<Future<bool>> onBackButtonPressed;

  @override
  _BackButtonListenerState createState() => _BackButtonListenerState();
}

class _BackButtonListenerState extends State<BackButtonListener> {
  BackButtonDispatcher? dispatcher;

  @override
  void didChangeDependencies() {
    dispatcher?.removeCallback(widget.onBackButtonPressed);

    final BackButtonDispatcher? rootBackDispatcher = Router.of(context).backButtonDispatcher;
    assert(rootBackDispatcher != null, 'The parent router must have a backButtonDispatcher to use this widget');

    dispatcher = rootBackDispatcher!.createChildBackButtonDispatcher()
      ..addCallback(widget.onBackButtonPressed)
      ..takePriority();
    super.didChangeDependencies();
  }

  @override
  void didUpdateWidget(covariant BackButtonListener oldWidget) {
    if (oldWidget.onBackButtonPressed != widget.onBackButtonPressed) {
      dispatcher?.removeCallback(oldWidget.onBackButtonPressed);
      dispatcher?.addCallback(widget.onBackButtonPressed);
      dispatcher?.takePriority();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    dispatcher?.removeCallback(widget.onBackButtonPressed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A delegate that is used by the [Router] widget to parse a route information
/// into a configuration of type T.
///
/// This delegate is used when the [Router] widget is first built with initial
/// route information from [Router.routeInformationProvider] and any subsequent
/// new route notifications from it. The [Router] widget calls the [parseRouteInformation]
/// with the route information from [Router.routeInformationProvider].
abstract class RouteInformationParser<T> {
  /// Abstract const constructor. This constructor enables subclasses to provide
  /// const constructors so that they can be used in const expressions.
  const RouteInformationParser();

  /// Converts the given route information into parsed data to pass to a
  /// [RouterDelegate].
  ///
  /// The method should return a future which completes when the parsing is
  /// complete. The parsing may be asynchronous if, e.g., the parser needs to
  /// communicate with the OEM thread to obtain additional data about the route.
  ///
  /// Consider using a [SynchronousFuture] if the result can be computed
  /// synchronously, so that the [Router] does not need to wait for the next
  /// microtask to pass the data to the [RouterDelegate].
  Future<T> parseRouteInformation(RouteInformation routeInformation);

  /// Restore the route information from the given configuration.
  ///
  /// This may return null, in which case the browser history will not be updated.
  /// See [Router]'s documentation for details.
  ///
  /// The [parseRouteInformation] method must produce an equivalent
  /// configuration when passed this method's return value.
  RouteInformation? restoreRouteInformation(T configuration) => null;
}

/// A delegate that is used by the [Router] widget to build and configure a
/// navigating widget.
///
/// This delegate is the core piece of the [Router] widget. It responds to
/// push route and pop route intents from the engine and notifies the [Router]
/// to rebuild. It also acts as a builder for the [Router] widget and builds a
/// navigating widget, typically a [Navigator], when the [Router] widget
/// builds.
///
/// When the engine pushes a new route, the route information is parsed by the
/// [RouteInformationParser] to produce a configuration of type T. The router
/// delegate receives the configuration through [setInitialRoutePath] or
/// [setNewRoutePath] to configure itself and builds the latest navigating
/// widget when asked ([build]).
///
/// When implementing subclasses, consider defining a [Listenable] app state object to be
/// used for building the navigating widget. The router delegate would update
/// the app state accordingly and notify its own listeners when the app state has
/// changed and when it receive route related engine intents (e.g.
/// [setNewRoutePath], [setInitialRoutePath], or [popRoute]).
///
/// All subclass must implement [setNewRoutePath], [popRoute], and [build].
///
/// See also:
///
///  * [RouteInformationParser], which is responsible for parsing the route
///    information to a configuration before passing in to router delegate.
///  * [Router], which is the widget that wires all the delegates together to
///    provide a fully functional routing solution.
abstract class RouterDelegate<T> extends Listenable {
  /// Called by the [Router] at startup with the structure that the
  /// [RouteInformationParser] obtained from parsing the initial route.
  ///
  /// This should configure the [RouterDelegate] so that when [build] is
  /// invoked, it will create a widget tree that matches the initial route.
  ///
  /// By default, this method forwards the [configuration] to [setNewRoutePath].
  ///
  /// Consider using a [SynchronousFuture] if the result can be computed
  /// synchronously, so that the [Router] does not need to wait for the next
  /// microtask to schedule a build.
  Future<void> setInitialRoutePath(T configuration) {
    return setNewRoutePath(configuration);
  }

  /// Called by the [Router] when the [Router.routeInformationProvider] reports that a
  /// new route has been pushed to the application by the operating system.
  ///
  /// Consider using a [SynchronousFuture] if the result can be computed
  /// synchronously, so that the [Router] does not need to wait for the next
  /// microtask to schedule a build.
  Future<void> setNewRoutePath(T configuration);

  /// Called by the [Router] when the [Router.backButtonDispatcher] reports that
  /// the operating system is requesting that the current route be popped.
  ///
  /// The method should return a boolean [Future] to indicate whether this
  /// delegate handles the request. Returning false will cause the entire app
  /// to be popped.
  ///
  /// Consider using a [SynchronousFuture] if the result can be computed
  /// synchronously, so that the [Router] does not need to wait for the next
  /// microtask to schedule a build.
  Future<bool> popRoute();

  /// Called by the [Router] when it detects a route information may have
  /// changed as a result of rebuild.
  ///
  /// If this getter returns non-null, the [Router] will start to report new
  /// route information back to the engine. In web applications, the new
  /// route information is used for populating browser history in order to
  /// support the forward and the backward buttons.
  ///
  /// When overriding this method, the configuration returned by this getter
  /// must be able to construct the current app state and build the widget
  /// with the same configuration in the [build] method if it is passed back
  /// to the [setNewRoutePath]. Otherwise, the browser backward and forward
  /// buttons will not work properly.
  ///
  /// By default, this getter returns null, which prevents the [Router] from
  /// reporting the route information. To opt in, a subclass can override this
  /// getter to return the current configuration.
  ///
  /// At most one [Router] can opt in to route information reporting. Typically,
  /// only the top-most [Router] created by [WidgetsApp.router] should opt for
  /// route information reporting.
  T? get currentConfiguration => null;

  /// Called by the [Router] to obtain the widget tree that represents the
  /// current state.
  ///
  /// This is called whenever the [setInitialRoutePath] method's future
  /// completes, the [setNewRoutePath] method's future completes with the value
  /// true, the [popRoute] method's future completes with the value true, or
  /// this object notifies its clients (see the [Listenable] interface, which
  /// this interface includes). In addition, it may be called at other times. It
  /// is important, therefore, that the methods above do not update the state
  /// that the [build] method uses before they complete their respective
  /// futures.
  ///
  /// Typically this method returns a suitably-configured [Navigator]. If you do
  /// plan to create a navigator, consider using the
  /// [PopNavigatorRouterDelegateMixin].
  ///
  /// This method must not return null.
  ///
  /// The `context` is the [Router]'s build context.
  Widget build(BuildContext context);
}

/// A route information provider that provides route information for the
/// [Router] widget
///
/// This provider is responsible for handing the route information through [value]
/// getter and notifies listeners, typically the [Router] widget, when a new
/// route information is available.
///
/// When the router opts for route information reporting (by overriding the
/// [RouterDelegate.currentConfiguration] to return non-null), override the
/// [routerReportsNewRouteInformation] method to process the route information.
///
/// See also:
///
///  * [PlatformRouteInformationProvider], which wires up the itself with the
///    [WidgetsBindingObserver.didPushRoute] to propagate platform push route
///    intent to the [Router] widget, as well as reports new route information
///    from the [Router] back to the engine by overriding the
///    [routerReportsNewRouteInformation].
abstract class RouteInformationProvider extends ValueListenable<RouteInformation?> {
  /// A callback called when the [Router] widget detects any navigation event
  /// due to state changes.
  ///
  /// The subclasses can override this method to update theirs values or trigger
  /// other side effects. For example, the [PlatformRouteInformationProvider]
  /// overrides this method to report the route information back to the engine.
  ///
  /// The [routeInformation] is the new route information after the navigation
  /// event.
  void routerReportsNewRouteInformation(RouteInformation routeInformation) {}
}

/// The route information provider that propagates the platform route information changes.
///
/// This provider also reports the new route information from the [Router] widget
/// back to engine using message channel method, the
/// [SystemNavigator.routeInformationUpdated].
class PlatformRouteInformationProvider extends RouteInformationProvider with WidgetsBindingObserver, ChangeNotifier {
  /// Create a platform route information provider.
  ///
  /// Use the [initialRouteInformation] to set the default route information for this
  /// provider.
  PlatformRouteInformationProvider({
    RouteInformation? initialRouteInformation,
  }) : _value = initialRouteInformation;

  @override
  void routerReportsNewRouteInformation(RouteInformation routeInformation) {
    SystemNavigator.routeInformationUpdated(
      location: routeInformation.location!,
      state: routeInformation.state,
    );
    _value = routeInformation;
  }

  @override
  RouteInformation? get value => _value;
  RouteInformation? _value;

  void _platformReportsNewRouteInformation(RouteInformation routeInformation) {
    if (_value == routeInformation)
      return;
    _value = routeInformation;
    notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) {
    if (!hasListeners)
      WidgetsBinding.instance!.addObserver(this);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners)
      WidgetsBinding.instance!.removeObserver(this);
  }

  @override
  void dispose() {
    // In practice, this will rarely be called. We assume that the listeners
    // will be added and removed in a coherent fashion such that when the object
    // is no longer being used, there's no listener, and so it will get garbage
    // collected.
    if (hasListeners)
      WidgetsBinding.instance!.removeObserver(this);
    super.dispose();
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    assert(hasListeners);
    _platformReportsNewRouteInformation(routeInformation);
    return true;
  }

  @override
  Future<bool> didPushRoute(String route) async {
    assert(hasListeners);
    _platformReportsNewRouteInformation(RouteInformation(location: route));
    return true;
  }
}

/// A mixin that wires [RouterDelegate.popRoute] to the [Navigator] it builds.
///
/// This mixin calls [Navigator.maybePop] when it receives an Android back
/// button intent through the [RouterDelegate.popRoute]. Using this mixin
/// guarantees that the back button still respects pageless routes in the
/// navigator.
///
/// Only use this mixin if you plan to build a navigator in the
/// [RouterDelegate.build].
mixin PopNavigatorRouterDelegateMixin<T> on RouterDelegate<T> {
  /// The key used for retrieving the current navigator.
  ///
  /// When using this mixin, be sure to use this key to create the navigator.
  GlobalKey<NavigatorState>? get navigatorKey;

  @override
  Future<bool> popRoute() {
    final NavigatorState? navigator = navigatorKey?.currentState;
    if (navigator == null)
      return SynchronousFuture<bool>(false);
    return navigator.maybePop();
  }
}
