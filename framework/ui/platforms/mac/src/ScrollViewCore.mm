#include <bdn/init.h>
#import <bdn/mac/ScrollViewCore.hh>

#include <bdn/ScrollViewLayoutHelper.h>
#import <bdn/mac/util.hh>

#import <Cocoa/Cocoa.h>

/** NSView implementation that is used internally by bdn::mac::ScrollViewCore.

 Sets the flipped property so that the coordinate system has its origin in the
 top left, rather than the bottom left.
 */
@interface BdnMacScrollView_ : NSScrollView

@end

@implementation BdnMacScrollView_

- (BOOL)isFlipped { return YES; }

@end

@interface BdnMacScrollViewContentViewParent_ : NSView

@end

@implementation BdnMacScrollViewContentViewParent_

- (BOOL)isFlipped { return YES; }

@end

@interface BdnMacScrollViewCoreEventForwarder_ : NSObject

@property bdn::mac::ScrollViewCore *scrollViewCore;

@end

@implementation BdnMacScrollViewCoreEventForwarder_

- (void)setScrollViewCore:(bdn::mac::ScrollViewCore *)core { _scrollViewCore = core; }

- (void)contentViewBoundsDidChange { _scrollViewCore->_contentViewBoundsDidChange(); }

@end

namespace bdn
{
    namespace mac
    {

        ScrollViewCore::ScrollViewCore(ScrollView *outer) : ChildViewCore(outer, _createScrollView(outer))
        {
            _nsScrollView = (NSScrollView *)getNSView();

            // we add a custom view as the document view so that we have better
            // control over the positioning of the content view
            _nsContentViewParent = [[BdnMacScrollViewContentViewParent_ alloc] initWithFrame:NSMakeRect(0, 0, 0, 0)];

            _nsScrollView.documentView = _nsContentViewParent;

            _nsScrollView.autohidesScrollers = YES;

            _nsScrollView.contentView.postsBoundsChangedNotifications = YES;

            BdnMacScrollViewCoreEventForwarder_ *eventForwarder = [BdnMacScrollViewCoreEventForwarder_ alloc];
            [eventForwarder setScrollViewCore:this];
            _eventForwarder = eventForwarder;

            [[NSNotificationCenter defaultCenter] addObserver:eventForwarder
                                                     selector:@selector(contentViewBoundsDidChange)
                                                         name:NSViewBoundsDidChangeNotification
                                                       object:_nsScrollView.contentView];

            setHorizontalScrollingEnabled(outer->horizontalScrollingEnabled());
            setVerticalScrollingEnabled(outer->verticalScrollingEnabled());

            setPadding(outer->padding());
        }

        ScrollViewCore::~ScrollViewCore()
        {
            [[NSNotificationCenter defaultCenter] removeObserver:_eventForwarder
                                                            name:NSViewBoundsDidChangeNotification
                                                          object:_nsScrollView.contentView];
        }

        NSScrollView *ScrollViewCore::_createScrollView(ScrollView *outer)
        {
            NSScrollView *scrollView = [[BdnMacScrollView_ alloc] initWithFrame:NSMakeRect(0, 0, 0, 0)];

            return scrollView;
        }

        void ScrollViewCore::addChildNsView(NSView *childView)
        {
            // replace any previous subview

            for (id oldViewObject in _nsScrollView.documentView.subviews) {
                NSView *oldView = (NSView *)oldViewObject;

                [oldView removeFromSuperview];
            }

            [_nsScrollView.documentView addSubview:childView];
        }

        void ScrollViewCore::setPadding(const Nullable<UiMargin> &padding)
        {
            // nothing to do
        }

        void ScrollViewCore::setHorizontalScrollingEnabled(const bool &enabled)
        {
            _nsScrollView.hasHorizontalScroller = enabled ? YES : NO;
        }

        void ScrollViewCore::setVerticalScrollingEnabled(const bool &enabled)
        {
            _nsScrollView.hasVerticalScroller = enabled ? YES : NO;
        }

        P<ScrollViewLayoutHelper> ScrollViewCore::createLayoutHelper(Size *borderSize) const
        {
            // first we need to find out the size of the border around the
            // scroll view and the space needed for scrollbars.
            double vertBarWidth = 0;
            double horzBarHeight = 0;
            Size borderSize;

            // first we need to find out the size of the border around the
            // scroll view and the space needed for scrollbars.

            // Note that the "content size" for NSScrollView is the size of the
            // visible content inside the scroll view, not the whole content
            // size. NSScrollView calls the whole content size the document
            // size.
            Size frameSize(500, 500);
            NSSize macFrameSize = sizeToMacSize(frameSize);

            NSSize macSizeWithScrollers = [NSScrollView contentSizeForFrameSize:macFrameSize
                                                        horizontalScrollerClass:[NSScroller class]
                                                          verticalScrollerClass:[NSScroller class]
                                                                     borderType:_nsScrollView.borderType
                                                                    controlSize:NSControlSizeRegular
                                                                  scrollerStyle:_nsScrollView.scrollerStyle];

            NSSize macSizeWithoutScrollers = [NSScrollView contentSizeForFrameSize:macFrameSize
                                                           horizontalScrollerClass:nil
                                                             verticalScrollerClass:nil
                                                                        borderType:_nsScrollView.borderType
                                                                       controlSize:NSControlSizeRegular
                                                                     scrollerStyle:_nsScrollView.scrollerStyle];

            Size sizeWithScrollers = macSizeToSize(macSizeWithScrollers);
            Size sizeWithoutScrollers = macSizeToSize(macSizeWithoutScrollers);

            borderSize = frameSize - sizeWithoutScrollers;

            Size scrollerOverhead = sizeWithoutScrollers - sizeWithScrollers;
            vertBarWidth = scrollerOverhead.width;
            horzBarHeight = scrollerOverhead.height;

            if (borderSize != nullptr)
                *borderSize = borderSize;

            return newObj<ScrollViewLayoutHelper>(vertBarWidth, horzBarHeight);
        }

        Size ScrollViewCore::calcPreferredSize(const Size &availableSpace) const
        {
            Size preferredSize;

            P<ScrollView> outerView = cast<ScrollView>(getOuterViewIfStillAttached());
            if (outerView != nullptr) {
                P<ScrollViewLayoutHelper> helper = createLayoutHelper();

                preferredSize = helper->calcPreferredSize(outerView, availableSpace);
            }

            return preferredSize;
        }

        void ScrollViewCore::layout()
        {
            P<ScrollView> outerView = cast<ScrollView>(getOuterViewIfStillAttached());
            if (outerView != nullptr) {
                Size borderSize;
                P<ScrollViewLayoutHelper> helper = createLayoutHelper(&borderSize);

                Size viewPortSizeWithoutScrollbars = outerView->size() - borderSize;

                helper->calcLayout(outerView, viewPortSizeWithoutScrollbars);

                P<View> contentView = outerView->getContentView();
                if (contentView != nullptr) {
                    Rect contentBounds = helper->getContentViewBounds();

                    contentView->adjustAndSetBounds(contentBounds);

                    // we must also resize our content view parent accordingly.
                    Size scrolledAreaSize = helper->getScrolledAreaSize();

                    NSSize wrapperSize = sizeToMacSize(scrolledAreaSize);

                    [_nsScrollView.documentView setFrameSize:wrapperSize];
                }

                updateVisibleClientRect();
            }
        }

        void ScrollViewCore::scrollClientRectToVisible(const Rect &clientRect)
        {
            if (_nsScrollView.contentView != nil) {
                [_nsScrollView.contentView scrollRectToVisible:rectToMacRect(clientRect, -1)];
            }
        }

        void ScrollViewCore::_contentViewBoundsDidChange()
        {
            // when the view scrolls then the bounds of the content view (not
            // the document view) change.
            updateVisibleClientRect();
        }

        void ScrollViewCore::updateVisibleClientRect()
        {
            P<ScrollView> outerView = cast<ScrollView>(getOuterViewIfStillAttached());
            if (outerView != nullptr) {
                Rect visibleClientRect = macRectToRect(_nsScrollView.documentVisibleRect, -1);

                outerView->_setVisibleClientRect(visibleClientRect);
            }
        }
    }
}
